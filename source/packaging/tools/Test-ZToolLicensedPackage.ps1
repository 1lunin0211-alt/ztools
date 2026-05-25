param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-StrongNameSignature([string]$Path) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ZToolStrongNameNative {
  [DllImport("mscoree.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern bool StrongNameSignatureVerificationEx(string wszFilePath, bool fForceVerification, ref bool pfWasVerified);
}
'@ -ErrorAction SilentlyContinue

    $wasVerified = $false
    $ok = [ZToolStrongNameNative]::StrongNameSignatureVerificationEx($Path, $true, [ref]$wasVerified)
    [pscustomobject]@{
        Path = $Path
        Ok = [bool]$ok
        WasVerified = [bool]$wasVerified
        Win32Error = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    }
}

function Get-AssemblyPublicConstant([string]$Path, [string]$TypeName, [string]$FieldName) {
    $assembly = [System.Reflection.Assembly]::LoadFile($Path)
    $type = $assembly.GetType($TypeName, $true)
    $field = $type.GetField($FieldName, [System.Reflection.BindingFlags]'Public,Static')
    if ($null -eq $field) {
        throw "Field not found: $TypeName.$FieldName"
    }

    [string]$field.GetRawConstantValue()
}

function Test-RsaPublicKeyXml([string]$Xml) {
    $trimmed = $Xml.Trim()
    if (-not $trimmed.StartsWith('<RSAKeyValue', [System.StringComparison]::Ordinal) -or
        -not $trimmed.EndsWith('</RSAKeyValue>', [System.StringComparison]::Ordinal)) {
        return $false
    }

    try {
        $rsa = [System.Security.Cryptography.RSACryptoServiceProvider]::new()
        try {
            $rsa.FromXmlString($trimmed)
        } finally {
            $rsa.Dispose()
        }
        return $true
    } catch {
        return $false
    }
}

function Get-DnlibPath {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $tfm = if ($PSVersionTable.PSEdition -eq 'Core') { 'netstandard2.0' } else { 'net45' }
    $candidates = @(
        (Join-Path $repoRoot "_archive\_reverse\packages\dnlib\lib\$tfm\dnlib.dll"),
        (Join-Path $repoRoot '_archive\_reverse\packages\dnlib\lib\net45\dnlib.dll'),
        (Join-Path $repoRoot '_archive\_reverse\packages\dnlib\lib\netstandard2.0\dnlib.dll')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    throw 'dnlib.dll was not found; cannot inspect encrypted ZTool.exe payload.'
}

function Ensure-DnlibLoaded {
    if ('dnlib.DotNet.ModuleDefMD' -as [type]) {
        return
    }

    Add-Type -Path (Get-DnlibPath)
}

function Get-EmbeddedResourceBytes([string]$Path, [string]$ResourceName) {
    Ensure-DnlibLoaded

    $module = [dnlib.DotNet.ModuleDefMD]::Load($Path)
    try {
        foreach ($resource in $module.Resources) {
            $embedded = $resource -as [dnlib.DotNet.EmbeddedResource]
            if ($null -eq $embedded -or [string]$resource.Name -ne $ResourceName) {
                continue
            }

            $reader = $embedded.CreateReader()
            return $reader.ReadBytes([int]$reader.Length)
        }
    } finally {
        $module.Dispose()
    }

    throw "Embedded resource not found: $ResourceName"
}

function ConvertFrom-ZToolPayloadResource([byte[]]$EncryptedPayload) {
    $des = [System.Security.Cryptography.DES]::Create()
    $des.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $des.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $des.Key = [byte[]](0x21,0x1B,0x53,0x5B,0x11,0x12,0x2D,0x4C)
    $des.IV = [byte[]](0x35,0x27,0x13,0x26,0x63,0x16,0x2F,0x34)
    $decryptor = $des.CreateDecryptor()
    try {
        $plain = $decryptor.TransformFinalBlock($EncryptedPayload, 0, $EncryptedPayload.Length)
    } finally {
        $decryptor.Dispose()
        $des.Dispose()
    }

    $base64 = [System.Text.Encoding]::UTF8.GetString($plain).TrimStart([char]0xFEFF).Trim()
    [Convert]::FromBase64String($base64)
}

function Get-DnlibMethod([dnlib.DotNet.ModuleDef]$Module, [string]$TypeName, [string]$MethodName) {
    $type = $Module.Find($TypeName, $true)
    if ($null -eq $type) {
        throw "Type not found: $TypeName"
    }

    foreach ($method in $type.Methods) {
        if ([string]$method.Name -eq $MethodName) {
            if (-not $method.HasBody) {
                throw "Method has no body: $TypeName::$MethodName"
            }

            return $method
        }
    }

    throw "Method not found: $TypeName::$MethodName"
}

function Get-InstructionIndex($Instructions, [dnlib.DotNet.Emit.Instruction]$Target) {
    for ($i = 0; $i -lt $Instructions.Count; $i++) {
        if ([object]::ReferenceEquals($Instructions[$i], $Target)) {
            return $i
        }
    }

    return -1
}

function Get-NextNonNopInstructionIndex($Instructions, [int]$StartIndex) {
    for ($i = $StartIndex; $i -lt $Instructions.Count; $i++) {
        if ($Instructions[$i].OpCode -ne [dnlib.DotNet.Emit.OpCodes]::Nop) {
            return $i
        }
    }

    return -1
}

function Test-InstructionBranchesOutBeforeRun($Instructions, [int]$InstructionIndex, [int]$RunIndex) {
    if ($InstructionIndex -lt 0 -or $InstructionIndex -ge $Instructions.Count) {
        return $false
    }

    $instruction = $Instructions[$InstructionIndex]
    if ($instruction.OpCode -eq [dnlib.DotNet.Emit.OpCodes]::Ret) {
        return $true
    }

    if ($instruction.OpCode -ne [dnlib.DotNet.Emit.OpCodes]::Br -and
        $instruction.OpCode -ne [dnlib.DotNet.Emit.OpCodes]::Br_S -and
        $instruction.OpCode -ne [dnlib.DotNet.Emit.OpCodes]::Leave -and
        $instruction.OpCode -ne [dnlib.DotNet.Emit.OpCodes]::Leave_S) {
        return $false
    }

    $target = $instruction.Operand -as [dnlib.DotNet.Emit.Instruction]
    if ($null -eq $target) {
        return $false
    }

    $targetIndex = Get-InstructionIndex $Instructions $target
    return $targetIndex -gt $RunIndex -or $target.OpCode -eq [dnlib.DotNet.Emit.OpCodes]::Ret
}

function Test-CodeStaticConstructorDoesNotCallLicenseGate([dnlib.DotNet.ModuleDef]$Module) {
    $method = Get-DnlibMethod $Module 'ZTool.code' '.cctor'
    $instructions = $method.Body.Instructions

    for ($i = 0; $i -lt $instructions.Count; $i++) {
        $methodOperand = $instructions[$i].Operand -as [dnlib.DotNet.IMethod]
        if ($null -ne $methodOperand -and [string]$methodOperand.FullName -eq 'System.Boolean ZTool.License.LicenseGate::IsLicensed()') {
            return $false
        }
    }

    return $true
}

function Test-DnlibMethodReferences([dnlib.DotNet.MethodDef]$Method, [string]$FullName) {
    foreach ($instruction in $Method.Body.Instructions) {
        $operand = $instruction.Operand
        if ($null -ne $operand -and [string]$operand -eq $FullName) {
            return $true
        }
    }

    return $false
}

function Test-DnlibMethodLoadsString([dnlib.DotNet.MethodDef]$Method, [string]$Value) {
    foreach ($instruction in $Method.Body.Instructions) {
        if ($instruction.OpCode -eq [dnlib.DotNet.Emit.OpCodes]::Ldstr -and [string]$instruction.Operand -eq $Value) {
            return $true
        }
    }

    return $false
}

function Test-FrmmainSolidWorksLaunchAutoConnect([dnlib.DotNet.ModuleDef]$Module) {
    $errors = New-Object System.Collections.Generic.List[string]
    $connect = 'System.Void ZTool.Frmmain::_ConnectSW_ExecuteEvent(System.Object,RibbonLib.Controls.Events.ExecuteEventArgs)'
    $receiverHwnd = 'System.IntPtr ZTool.code::Receiver_hWnd'
    $startType = 'System.String ZTool.Program::StartType'
    $openid = 'System.String ZTool.Frmmain::openid'

    $loadMethod = Get-DnlibMethod $Module 'ZTool.Frmmain' 'Frmmain_Load'
    if (-not (Test-DnlibMethodReferences $loadMethod $connect)) {
        $errors.Add('ZTool.Frmmain::Frmmain_Load does not auto-run the Connect SW route after a SolidWorks toolbar launch.')
    }
    if (-not (Test-DnlibMethodReferences $loadMethod $receiverHwnd)) {
        $errors.Add('ZTool.Frmmain::Frmmain_Load auto-connect is not guarded by ZTool.code::Receiver_hWnd.')
    }
    if (-not (Test-DnlibMethodReferences $loadMethod $startType)) {
        $errors.Add('ZTool.Frmmain::Frmmain_Load auto-connect is not limited to Program.StartType=0.')
    }

    $bringToFrontMethod = Get-DnlibMethod $Module 'ZTool.Frmmain' 'BringToFrontSafely'
    if (-not (Test-DnlibMethodReferences $bringToFrontMethod $connect)) {
        $errors.Add('ZTool.Frmmain::BringToFrontSafely does not reconnect when SolidWorks sends the existing-window StartType=0 command.')
    }
    if (-not (Test-DnlibMethodReferences $bringToFrontMethod $receiverHwnd)) {
        $errors.Add('ZTool.Frmmain::BringToFrontSafely reconnect is not guarded by ZTool.code::Receiver_hWnd.')
    }
    if (-not (Test-DnlibMethodReferences $bringToFrontMethod $openid) -or -not (Test-DnlibMethodLoadsString $bringToFrontMethod '1000')) {
        $errors.Add('ZTool.Frmmain::BringToFrontSafely reconnect is not limited to the openid=1000 main editor command.')
    }

    return $errors
}

function Test-DnlibMethodStoresFalseToCanrun([dnlib.DotNet.MethodDef]$Method) {
    $instructions = $Method.Body.Instructions
    for ($i = 0; $i -lt $instructions.Count; $i++) {
        if ($instructions[$i].OpCode -ne [dnlib.DotNet.Emit.OpCodes]::Ldc_I4_0) {
            continue
        }

        $storeIndex = Get-NextNonNopInstructionIndex $instructions ($i + 1)
        if ($storeIndex -lt 0) {
            continue
        }

        $fieldOperand = $instructions[$storeIndex].Operand -as [dnlib.DotNet.IField]
        if ($instructions[$storeIndex].OpCode -eq [dnlib.DotNet.Emit.OpCodes]::Stsfld -and
            $null -ne $fieldOperand -and
            [string]$fieldOperand.FullName -eq 'System.Boolean ZTool.code::canrun') {
            return $true
        }
    }

    return $false
}

function Test-LegacyChecklicTimerDisabled([dnlib.DotNet.ModuleDef]$Module) {
    $errors = New-Object System.Collections.Generic.List[string]
    $ctor = Get-DnlibMethod $Module 'ZTool.JDK.checklic' '.ctor'
    $elapsed = Get-DnlibMethod $Module 'ZTool.JDK.checklic' 'tmr_Elapsed'

    if (Test-DnlibMethodReferences $ctor 'System.Void System.Timers.Timer::.ctor(System.Double)') {
        $errors.Add('ZTool.JDK.checklic::.ctor still starts the legacy dongle timer during Connect SW.')
    }

    foreach ($forbidden in @(
        'System.Boolean ZTool.JDK.Prog1::exit_g()',
        'System.Boolean ZTool.JDK.Prog2::exit_g()',
        'System.Boolean ZTool.SR::IsReg2(System.String,System.String&,System.String&)'
    )) {
        if (Test-DnlibMethodReferences $elapsed $forbidden) {
            $errors.Add("ZTool.JDK.checklic::tmr_Elapsed still depends on the old dongle/license path: $forbidden")
        }
    }

    if (Test-DnlibMethodStoresFalseToCanrun $elapsed) {
        $errors.Add('ZTool.JDK.checklic::tmr_Elapsed can still reset ZTool.code::canrun to false after demo activation.')
    }

    return $errors
}

function Test-LicenseAssemblyReferencesUsePublicKeyToken([dnlib.DotNet.ModuleDef]$Module, [string]$ModuleLabel, [string]$ExpectedToken, [bool]$RequireReference = $true) {
    $errors = New-Object System.Collections.Generic.List[string]
    $refs = @($Module.GetAssemblyRefs() | Where-Object { [string]$_.Name -eq 'ZTool.License' })
    if ($refs.Count -eq 0) {
        if ($RequireReference) {
            $errors.Add("$ModuleLabel does not reference ZTool.License; license gate patch is missing.")
        }

        return $errors
    }

    foreach ($assemblyRef in $refs) {
        $publicKeyOrToken = [string]$assemblyRef.PublicKeyOrToken
        if ($null -eq $publicKeyOrToken) {
            $publicKeyOrToken = ''
        }

        $publicKeyOrToken = $publicKeyOrToken.ToLowerInvariant()
        if ($assemblyRef.HasPublicKey) {
            $errors.Add("$ModuleLabel references ZTool.License with a full public key instead of public-key token $ExpectedToken.")
        }

        if ($publicKeyOrToken -ne $ExpectedToken) {
            $errors.Add("$ModuleLabel references ZTool.License with invalid public key token/reference '$publicKeyOrToken' (expected '$ExpectedToken').")
        }
    }

    return $errors
}

function Test-NoTokenSizedPublicKeyAssemblyRefs([dnlib.DotNet.ModuleDef]$Module, [string]$ModuleLabel) {
    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($assemblyRef in $Module.GetAssemblyRefs()) {
        $publicKeyOrToken = [string]$assemblyRef.PublicKeyOrToken
        if (-not $assemblyRef.HasPublicKey -or
            [string]::IsNullOrWhiteSpace($publicKeyOrToken) -or
            $publicKeyOrToken.Length -ne 16 -or
            $publicKeyOrToken -notmatch '^[0-9a-fA-F]{16}$') {
            continue
        }

        $errors.Add("$ModuleLabel has invalid strong-name AssemblyRef '$($assemblyRef.Name)': HasPublicKey=true but value '$publicKeyOrToken' is token-sized. This crashes the CLR with 0x8013141E; use the original full public key or mark it as PublicKeyToken.")
    }

    return $errors
}

function Test-ProgramMainHasFailClosedLicenseGate([dnlib.DotNet.ModuleDef]$Module) {
    $method = Get-DnlibMethod $Module 'ZTool.Program' 'Main'
    $instructions = $method.Body.Instructions
    $runIndex = -1
    $licenseStoreIndex = -1

    for ($i = 0; $i -lt $instructions.Count; $i++) {
        $methodOperand = $instructions[$i].Operand -as [dnlib.DotNet.IMethod]
        if ($null -ne $methodOperand -and [string]$methodOperand.FullName -eq 'System.Void System.Windows.Forms.Application::Run(System.Windows.Forms.ApplicationContext)') {
            $runIndex = $i
            break
        }

        if ($null -ne $methodOperand -and [string]$methodOperand.FullName -eq 'System.Boolean ZTool.License.LicenseGate::IsLicensed()') {
            $storeIndex = Get-NextNonNopInstructionIndex $instructions ($i + 1)
            if ($storeIndex -ge 0) {
                $fieldOperand = $instructions[$storeIndex].Operand -as [dnlib.DotNet.IField]
                if ($instructions[$storeIndex].OpCode -eq [dnlib.DotNet.Emit.OpCodes]::Stsfld -and
                    $null -ne $fieldOperand -and
                    [string]$fieldOperand.FullName -eq 'System.Boolean ZTool.code::canrun') {
                    $licenseStoreIndex = $i
                }
            }
        }
    }

    if ($runIndex -lt 0) {
        return [pscustomobject]@{
            IsFailClosed = $false
            RunIndex = -1
            GateCount = 0
            HasLicenseStore = $licenseStoreIndex -ge 0
        }
    }

    $validGates = 0
    for ($i = 0; $i -lt $runIndex; $i++) {
        if ($instructions[$i].OpCode -ne [dnlib.DotNet.Emit.OpCodes]::Ldsfld) {
            continue
        }

        $fieldOperand = $instructions[$i].Operand -as [dnlib.DotNet.IField]
        if ($null -eq $fieldOperand -or [string]$fieldOperand.FullName -ne 'System.Boolean ZTool.code::canrun') {
            continue
        }

        $branchIndex = Get-NextNonNopInstructionIndex $instructions ($i + 1)
        if ($branchIndex -lt 0) {
            continue
        }

        $branch = $instructions[$branchIndex]
        $target = $branch.Operand -as [dnlib.DotNet.Emit.Instruction]
        $targetIndex = if ($null -eq $target) { -1 } else { Get-InstructionIndex $instructions $target }
        $fallthroughIndex = Get-NextNonNopInstructionIndex $instructions ($branchIndex + 1)

        if ($licenseStoreIndex -ge 0 -and
            $licenseStoreIndex -lt $i -and
            ($branch.OpCode -eq [dnlib.DotNet.Emit.OpCodes]::Brtrue -or
             $branch.OpCode -eq [dnlib.DotNet.Emit.OpCodes]::Brtrue_S) -and
            $targetIndex -gt $i -and
            $targetIndex -lt $runIndex -and
            (Test-InstructionBranchesOutBeforeRun $instructions $fallthroughIndex $runIndex)) {
            $validGates++
            continue
        }

        if ($licenseStoreIndex -ge 0 -and
            $licenseStoreIndex -lt $i -and
            ($branch.OpCode -eq [dnlib.DotNet.Emit.OpCodes]::Brfalse -or
             $branch.OpCode -eq [dnlib.DotNet.Emit.OpCodes]::Brfalse_S) -and
            (Test-InstructionBranchesOutBeforeRun $instructions $targetIndex $runIndex) -and
            $fallthroughIndex -gt $i -and
            $fallthroughIndex -lt $runIndex) {
            $validGates++
        }
    }

    [pscustomobject]@{
        IsFailClosed = $validGates -gt 0
        RunIndex = $runIndex
        GateCount = $validGates
        HasLicenseStore = $licenseStoreIndex -ge 0
    }
}

function Test-MethodStartsWithLicenseGate([dnlib.DotNet.MethodDef]$Method) {
    $instructions = $Method.Body.Instructions
    $callIndex = Get-NextNonNopInstructionIndex $instructions 0
    if ($callIndex -lt 0) {
        return $false
    }

    $callOperand = $instructions[$callIndex].Operand -as [dnlib.DotNet.IMethod]
    if ($instructions[$callIndex].OpCode -ne [dnlib.DotNet.Emit.OpCodes]::Call -or
        $null -eq $callOperand -or
        [string]$callOperand.FullName -ne 'System.Boolean ZTool.License.LicenseGate::IsLicensed()') {
        return $false
    }

    $branchIndex = Get-NextNonNopInstructionIndex $instructions ($callIndex + 1)
    if ($branchIndex -lt 0) {
        return $false
    }

    $branch = $instructions[$branchIndex]
    if ($branch.OpCode -ne [dnlib.DotNet.Emit.OpCodes]::Brtrue -and
        $branch.OpCode -ne [dnlib.DotNet.Emit.OpCodes]::Brtrue_S) {
        return $false
    }

    $target = $branch.Operand -as [dnlib.DotNet.Emit.Instruction]
    if ($null -eq $target -or (Get-InstructionIndex $instructions $target) -le $branchIndex) {
        return $false
    }

    $failIndex = Get-NextNonNopInstructionIndex $instructions ($branchIndex + 1)
    if ($failIndex -lt 0) {
        return $false
    }

    $returnType = [string]$Method.ReturnType.FullName
    if ($returnType -eq 'System.Void') {
        return $instructions[$failIndex].OpCode -eq [dnlib.DotNet.Emit.OpCodes]::Ret
    }

    if ($returnType -eq 'System.Boolean') {
        $retIndex = Get-NextNonNopInstructionIndex $instructions ($failIndex + 1)
        return $instructions[$failIndex].OpCode -eq [dnlib.DotNet.Emit.OpCodes]::Ldc_I4_0 -and
            $retIndex -ge 0 -and
            $instructions[$retIndex].OpCode -eq [dnlib.DotNet.Emit.OpCodes]::Ret
    }

    return $false
}

function Test-SolidWorksAddInLicenseBoundary([dnlib.DotNet.ModuleDef]$Module) {
    $type = $Module.Find('ZTool.SwAddin', $true)
    if ($null -eq $type) {
        throw 'Type not found: ZTool.SwAddin'
    }

    $perCommandGateCalls = New-Object System.Collections.Generic.List[string]
    $checked = 0
    foreach ($method in $type.Methods) {
        if (-not $method.HasBody) {
            continue
        }

        $name = [string]$method.Name
        if (-not $method.IsPublic -and
            -not $name.StartsWith('Menu', [System.StringComparison]::Ordinal) -and
            $name -ne 'openZtool' -and
            $name -ne 'FlyoutCallback1' -and
            $name -ne 'ConnectToSW') {
            continue
        }

        $checked++
        foreach ($instruction in $method.Body.Instructions) {
            $operand = $instruction.Operand -as [dnlib.DotNet.IMethod]
            if ($null -ne $operand -and [string]$operand.FullName -eq 'System.Boolean ZTool.License.LicenseGate::IsLicensed()') {
                $perCommandGateCalls.Add("ZTool.SwAddin::$name")
                break
            }
        }
    }

    [pscustomobject]@{
        Checked = $checked
        PerCommandGateCalls = $perCommandGateCalls
    }
}

function Test-SolidWorksAddInImageResourcesEmbedded([dnlib.DotNet.ModuleDef]$Module) {
    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

    $expected = @(
        @{ Name = 'ZTool.MainIconLarge_24.bmp'; Width = 24; Height = 24 },
        @{ Name = 'ZTool.MainIconLarge_32.bmp'; Width = 32; Height = 32 },
        @{ Name = 'ZTool.MainIconSmall_16.bmp'; Width = 16; Height = 16 },
        @{ Name = 'ZTool.ToolbarLarge_24.bmp'; Width = 432; Height = 24 },
        @{ Name = 'ZTool.ToolbarLarge_32.bmp'; Width = 576; Height = 32 },
        @{ Name = 'ZTool.ToolbarSmall_16.bmp'; Width = 288; Height = 16 },
        @{ Name = 'ZTool.flyGroupicon_16.png'; Width = 16; Height = 16 },
        @{ Name = 'ZTool.flyGroupicon_24.png'; Width = 24; Height = 24 },
        @{ Name = 'ZTool.flyGroupicon_32.png'; Width = 32; Height = 32 },
        @{ Name = 'ZTool.flyGroupiconlist_16.png'; Width = 32; Height = 16 },
        @{ Name = 'ZTool.flyGroupiconlist_24.png'; Width = 48; Height = 24 },
        @{ Name = 'ZTool.flyGroupiconlist_32.png'; Width = 64; Height = 32 }
    )

    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($item in $expected) {
        $resource = $null
        foreach ($candidate in $Module.Resources) {
            if ([string]$candidate.Name -eq $item.Name) {
                $resource = $candidate
                break
            }
        }

        if ($null -eq $resource) {
            $errors.Add("missing resource $($item.Name)")
            continue
        }

        $embedded = $resource -as [dnlib.DotNet.EmbeddedResource]
        if ($null -eq $embedded) {
            $errors.Add("$($item.Name) is $($resource.ResourceType), expected Embedded")
            continue
        }

        $reader = $embedded.CreateReader()
        $bytes = $reader.ReadBytes([int]$reader.Length)
        try {
            $stream = [System.IO.MemoryStream]::new($bytes)
            try {
                $image = [System.Drawing.Image]::FromStream($stream)
                try {
                    if ($image.Width -ne $item.Width -or $image.Height -ne $item.Height) {
                        $errors.Add("$($item.Name) has dimensions $($image.Width)x$($image.Height), expected $($item.Width)x$($item.Height)")
                    }
                } finally {
                    $image.Dispose()
                }
            } finally {
                $stream.Dispose()
            }
        } catch {
            $errors.Add("$($item.Name) is not a loadable image: $($_.Exception.Message)")
        }
    }

    return $errors
}

function Test-DnlibReturnsFalse([dnlib.DotNet.ModuleDef]$Module, [string]$TypeName, [string]$MethodName) {
    $method = Get-DnlibMethod $Module $TypeName $MethodName
    $ops = @($method.Body.Instructions | Where-Object { $_.OpCode -ne [dnlib.DotNet.Emit.OpCodes]::Nop })
    return $ops.Count -eq 2 -and
        $ops[0].OpCode -eq [dnlib.DotNet.Emit.OpCodes]::Ldc_I4_0 -and
        $ops[1].OpCode -eq [dnlib.DotNet.Emit.OpCodes]::Ret
}

function Test-DnlibReturnsVoid([dnlib.DotNet.ModuleDef]$Module, [string]$TypeName, [string]$MethodName) {
    $method = Get-DnlibMethod $Module $TypeName $MethodName
    $ops = @($method.Body.Instructions | Where-Object { $_.OpCode -ne [dnlib.DotNet.Emit.OpCodes]::Nop })
    return $ops.Count -eq 1 -and $ops[0].OpCode -eq [dnlib.DotNet.Emit.OpCodes]::Ret
}

function Test-DnlibReturnsString([dnlib.DotNet.ModuleDef]$Module, [string]$TypeName, [string]$MethodName, [string]$ExpectedValue) {
    $method = Get-DnlibMethod $Module $TypeName $MethodName
    $ops = @($method.Body.Instructions | Where-Object { $_.OpCode -ne [dnlib.DotNet.Emit.OpCodes]::Nop })
    return $ops.Count -eq 2 -and
        $ops[0].OpCode -eq [dnlib.DotNet.Emit.OpCodes]::Ldstr -and
        [string]$ops[0].Operand -eq $ExpectedValue -and
        $ops[1].OpCode -eq [dnlib.DotNet.Emit.OpCodes]::Ret
}

function Test-NoCheckUpdateShowCall([dnlib.DotNet.ModuleDef]$Module) {
    $hits = New-Object System.Collections.Generic.List[string]

    foreach ($type in $Module.GetTypes()) {
        foreach ($method in $type.Methods) {
            if (-not $method.HasBody) {
                continue
            }

            $instructions = $method.Body.Instructions
            for ($i = 0; $i -lt $instructions.Count; $i++) {
                $operand = $instructions[$i].Operand -as [dnlib.DotNet.IMethod]
                if ($null -eq $operand -or [string]$operand.Name -ne 'get_CheckUpdate') {
                    continue
                }

                $limit = [Math]::Min($instructions.Count - 1, $i + 5)
                for ($j = $i + 1; $j -le $limit; $j++) {
                    $next = $instructions[$j].Operand -as [dnlib.DotNet.IMethod]
                    if ($null -ne $next -and [string]$next.Name -eq 'Show') {
                        $hits.Add("$($type.FullName)::$($method.Name)")
                        break
                    }
                }
            }
        }
    }

    return $hits
}

function Test-WinFormsStartupBeforeProgramLicenseGate([dnlib.DotNet.ModuleDef]$Module) {
    $errors = New-Object System.Collections.Generic.List[string]
    $method = Get-DnlibMethod $Module 'ZTool.Program' 'Main'
    $instructions = $method.Body.Instructions
    $enableVisualStylesIndex = -1
    $setCompatibleTextRenderingDefaultIndex = -1
    $programLicenseGateIndex = -1
    $lateSetCompatibleTextRenderingDefault = New-Object System.Collections.Generic.List[int]

    for ($i = 0; $i -lt $instructions.Count; $i++) {
        $methodOperand = $instructions[$i].Operand -as [dnlib.DotNet.IMethod]
        if ($null -ne $methodOperand) {
            $fullName = [string]$methodOperand.FullName
            if ($fullName -eq 'System.Void System.Windows.Forms.Application::EnableVisualStyles()' -and $enableVisualStylesIndex -lt 0) {
                $enableVisualStylesIndex = $i
            }

            if ($fullName -eq 'System.Void System.Windows.Forms.Application::SetCompatibleTextRenderingDefault(System.Boolean)') {
                if ($setCompatibleTextRenderingDefaultIndex -lt 0) {
                    $setCompatibleTextRenderingDefaultIndex = $i
                }
            }

            if ($programLicenseGateIndex -lt 0 -and $fullName -eq 'System.Boolean ZTool.License.LicenseGate::IsLicensed()') {
                $programLicenseGateIndex = $i
            }
        }
    }

    if ($enableVisualStylesIndex -lt 0) {
        $errors.Add('ZTool.Program::Main does not call Application.EnableVisualStyles().')
    }
    if ($setCompatibleTextRenderingDefaultIndex -lt 0) {
        $errors.Add('ZTool.Program::Main does not call Application.SetCompatibleTextRenderingDefault(false).')
    }
    if ($programLicenseGateIndex -lt 0) {
        $errors.Add('ZTool.Program::Main does not call ZTool.License.LicenseGate::IsLicensed() directly.')
    }

    if ($enableVisualStylesIndex -ge 0 -and $programLicenseGateIndex -ge 0 -and $enableVisualStylesIndex -gt $programLicenseGateIndex) {
        $errors.Add("Application.EnableVisualStyles() must run before the Program.Main license gate (enable index=$enableVisualStylesIndex, license gate index=$programLicenseGateIndex).")
    }
    if ($setCompatibleTextRenderingDefaultIndex -ge 0 -and $programLicenseGateIndex -ge 0 -and $setCompatibleTextRenderingDefaultIndex -gt $programLicenseGateIndex) {
        $errors.Add("Application.SetCompatibleTextRenderingDefault(false) must run before the Program.Main license gate (set index=$setCompatibleTextRenderingDefaultIndex, license gate index=$programLicenseGateIndex).")
    }

    if ($programLicenseGateIndex -ge 0) {
        for ($i = $programLicenseGateIndex + 1; $i -lt $instructions.Count; $i++) {
            $methodOperand = $instructions[$i].Operand -as [dnlib.DotNet.IMethod]
            if ($null -ne $methodOperand -and [string]$methodOperand.FullName -eq 'System.Void System.Windows.Forms.Application::SetCompatibleTextRenderingDefault(System.Boolean)') {
                $lateSetCompatibleTextRenderingDefault.Add($i)
            }
        }
    }

    foreach ($lateIndex in $lateSetCompatibleTextRenderingDefault) {
        $errors.Add("Application.SetCompatibleTextRenderingDefault(false) is still called after license/UI startup can create windows (index=$lateIndex).")
    }

    return $errors
}

function Test-RegistrationTransferUsesOwnedDeactivation([dnlib.DotNet.ModuleDef]$Module) {
    $method = Get-DnlibMethod $Module 'ZTool.FrmRg' 'Button2_Click'
    $legacyCalls = New-Object System.Collections.Generic.List[string]
    $usesOwnedDeactivation = $false

    foreach ($instruction in $method.Body.Instructions) {
        $operand = $instruction.Operand -as [dnlib.DotNet.IMethod]
        if ($null -eq $operand) {
            continue
        }

        $fullName = [string]$operand.FullName
        if ($fullName -eq 'System.Boolean ZTool.License.LicenseGate::DeactivateWithPassword(System.String)') {
            $usesOwnedDeactivation = $true
        }

        if ($fullName -eq 'System.Boolean ZTool.TCPClient::Connect()' -or
            $fullName -eq 'System.Void ZTool.TCPClient::sendstring(ZTool.TCPClient/Sendtype,System.String)') {
            $legacyCalls.Add($fullName)
        }
    }

    [pscustomobject]@{
        UsesOwnedDeactivation = $usesOwnedDeactivation
        LegacyCalls = $legacyCalls
    }
}

$root = [System.IO.Path]::GetFullPath($PackageRoot)
$required = @(
    'ZTool.exe',
    'ZTool.dll',
    'ZTool.Init.exe',
    'ZTool.License.dll',
    'ZTool.settings',
    'help.CHM',
    'ZTool Updater.exe',
    'ZTool License Deactivate.exe',
    'Deactivate ZTool License.cmd',
    'Register ZTool SolidWorks AddIn.ps1',
    'Register ZTool SolidWorks AddIn.cmd',
    'Unregister ZTool SolidWorks AddIn.ps1',
    'Unregister ZTool SolidWorks AddIn.cmd'
)

$errors = New-Object System.Collections.Generic.List[string]
foreach ($relative in $required) {
    $path = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $errors.Add("Missing required file: $relative")
    }
}

foreach ($forbidden in @('ZTool.Core.exe', 'ZTool.Core.payload', 'ZTool.LicenseLauncher.config')) {
    if (Test-Path -LiteralPath (Join-Path $root $forbidden) -PathType Leaf) {
        $errors.Add("$forbidden must not be present in a production binary-fork package.")
    }
}

try {
    $helpPath = Join-Path $root 'help.CHM'
    $originalChineseHelpSha256 = '58278ECE494905BBA8282A1522D3A81DAF893C20C5EA11A76C9B2FDAD4DED45D'
    $helpSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $helpPath).Hash.ToUpperInvariant()
    if ($helpSha256 -eq $originalChineseHelpSha256) {
        $errors.Add('help.CHM is still the original Chinese help file; production package must include the Russian help.')
    }
} catch {
    $errors.Add("Cannot inspect help.CHM: $($_.Exception.Message)")
}

try {
    $settingsPath = Join-Path $root 'ZTool.settings'
    $settingsXml = [xml](Get-Content -LiteralPath $settingsPath -Raw)
    $swVersion = [int]$settingsXml.CConfigDO.SWver
    if ($swVersion -ne 0) {
        $errors.Add("ZTool.settings must use SolidWorks auto/current-version mode (<SWver>0</SWver>), actual SWver=$swVersion. Version-pinned values can target an unregistered SldWorks.Application.N ProgID and block standalone connection.")
    }

    $getDataOption = [int]$settingsXml.CConfigDO.GetDataOption
    if ($getDataOption -ne 0) {
        $errors.Add("ZTool.settings must default the Connect SW command to active SolidWorks/BOM mode (<GetDataOption>0</GetDataOption>), actual GetDataOption=$getDataOption. GetDataOption=4 opens the file-list workflow and leaves the assembly grid empty.")
    }
} catch {
    $errors.Add("Cannot inspect ZTool.settings SolidWorks version: $($_.Exception.Message)")
}

$expectedForkToken = '69848a58054312c2'
$expectedZToolProtocolToken = '9EF1CBF0BCFAD9F118EA30863B1874'
Ensure-DnlibLoaded
foreach ($relative in @('ZTool.exe', 'ZTool.dll', 'ZTool.Init.exe', 'ZTool.License.dll', 'ZTool Updater.exe', 'ZTool License Deactivate.exe')) {
    $path = Join-Path $root $relative
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $result = Test-StrongNameSignature $path
        if (-not $result.Ok -or -not $result.WasVerified) {
            $errors.Add("Strong-name verification failed: $relative (Win32Error=$($result.Win32Error))")
        }

        try {
            $name = [System.Reflection.AssemblyName]::GetAssemblyName($path)
            $token = -join ($name.GetPublicKeyToken() | ForEach-Object { $_.ToString('x2') })
            if ($token -ne $expectedForkToken) {
                $errors.Add("$relative is not signed with the fork public key token $expectedForkToken (actual: $token).")
            }
        } catch {
            $errors.Add("Cannot read $relative assembly metadata: $($_.Exception.Message)")
        }

        try {
            $module = [dnlib.DotNet.ModuleDefMD]::Load($path)
            try {
                foreach ($assemblyRefError in (Test-NoTokenSizedPublicKeyAssemblyRefs $module $relative)) {
                    $errors.Add($assemblyRefError)
                }
            } finally {
                $module.Dispose()
            }
        } catch {
            $errors.Add("Cannot inspect $relative AssemblyRefs: $($_.Exception.Message)")
        }
    }
}

try {
    $licensePath = Join-Path $root 'ZTool.License.dll'
    $licenseBaseUrl = Get-AssemblyPublicConstant $licensePath 'ZTool.License.EmbeddedLicenseConfig' 'LicenseBaseUrl'
    $activationHelpUrl = Get-AssemblyPublicConstant $licensePath 'ZTool.License.EmbeddedLicenseConfig' 'ActivationHelpUrl'
    $publicKeyXml = Get-AssemblyPublicConstant $licensePath 'ZTool.License.EmbeddedLicenseConfig' 'PublicKeyXml'
    if ($licenseBaseUrl.TrimEnd('/') -ne 'https://license.vizbuka.ru/ztool') {
        $errors.Add("ZTool.License.dll points to unexpected license server: $licenseBaseUrl")
    }
    if ([string]::IsNullOrWhiteSpace($activationHelpUrl) -or -not $activationHelpUrl.StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase)) {
        $errors.Add("ZTool.License.dll does not embed a valid activation help URL.")
    }
    if ([string]::IsNullOrWhiteSpace($publicKeyXml) -or -not (Test-RsaPublicKeyXml $publicKeyXml)) {
        $errors.Add("ZTool.License.dll does not embed a loadable raw RSA public key.")
    }

    $licenseAssembly = [System.Reflection.Assembly]::LoadFile($licensePath)
    $demoType = $licenseAssembly.GetType('ZTool.License.LicenseGate+DemoMode', $false)
    if ($null -eq $demoType) {
        $errors.Add("ZTool.License.dll does not contain the required demo mode timer.")
    } else {
        $demoMinutes = $demoType.GetField('DemoMinutes', [System.Reflection.BindingFlags]'NonPublic,Static')
        $demoEnv = $demoType.GetField('DemoSecondsEnvironmentVariable', [System.Reflection.BindingFlags]'NonPublic,Static')
        if ($null -eq $demoMinutes -or [int]$demoMinutes.GetRawConstantValue() -le 0) {
            $errors.Add("ZTool.License.dll demo mode has no positive production duration.")
        }
        if ($null -eq $demoEnv -or [string]$demoEnv.GetRawConstantValue() -ne 'ZTOOL_DEMO_SECONDS') {
            $errors.Add("ZTool.License.dll demo mode test timer override is missing.")
        }
    }
} catch {
    $errors.Add("Cannot read ZTool.License.dll embedded license config: $($_.Exception.Message)")
}

try {
    $exeName = [System.Reflection.AssemblyName]::GetAssemblyName((Join-Path $root 'ZTool.exe')).Name
    if ($exeName -ne 'ZTool') {
        $errors.Add("ZTool.exe is not the binary fork assembly.")
    }
} catch {
    $errors.Add("Cannot read ZTool.exe assembly metadata: $($_.Exception.Message)")
}

try {
    $payloadBytes = ConvertFrom-ZToolPayloadResource (Get-EmbeddedResourceBytes (Join-Path $root 'ZTool.exe') 'ZTool.9eAd0SlNKphk.png')

    $payloadTemp = Join-Path ([System.IO.Path]::GetTempPath()) ("ztool-payload-" + [guid]::NewGuid().ToString('N') + ".dll")
    try {
        [System.IO.File]::WriteAllBytes($payloadTemp, $payloadBytes)
        $payloadName = [System.Reflection.AssemblyName]::GetAssemblyName($payloadTemp)
        $payloadToken = -join ($payloadName.GetPublicKeyToken() | ForEach-Object { $_.ToString('x2') })
        if ($payloadName.Name -ne 'ZTool') {
            $errors.Add("ZTool.exe encrypted payload is not the ZTool assembly.")
        }
        if ($payloadToken -ne $expectedForkToken) {
            $errors.Add("ZTool.exe encrypted payload is not signed with the fork public key token $expectedForkToken (actual: $payloadToken).")
        }

        $payloadStrongName = Test-StrongNameSignature $payloadTemp
        if (-not $payloadStrongName.Ok -or -not $payloadStrongName.WasVerified) {
            $errors.Add("Strong-name verification failed for encrypted ZTool.exe payload (Win32Error=$($payloadStrongName.Win32Error))")
        }

        $payloadModule = [dnlib.DotNet.ModuleDefMD]::Load($payloadTemp)
        try {
            foreach ($assemblyRefError in (Test-NoTokenSizedPublicKeyAssemblyRefs $payloadModule 'ZTool.exe encrypted payload')) {
                $errors.Add($assemblyRefError)
            }

            foreach ($licenseRefError in (Test-LicenseAssemblyReferencesUsePublicKeyToken $payloadModule 'ZTool.exe encrypted payload' $expectedForkToken)) {
                $errors.Add($licenseRefError)
            }

            if (-not (Test-DnlibReturnsFalse $payloadModule 'ZTool.Frmmain' 'haveupdate')) {
                $errors.Add("ZTool.Frmmain::haveupdate is not disabled in the encrypted payload.")
            }

            if (-not (Test-DnlibReturnsString $payloadModule 'ZTool.code' 'Getpkt' $expectedZToolProtocolToken)) {
                $errors.Add("ZTool.code::Getpkt must return the original SolidWorks IPC token $expectedZToolProtocolToken. Re-signing ZTool.exe changes the derived token and makes the add-in silently ignore Connect SW requests.")
            }

            if (-not (Test-CodeStaticConstructorDoesNotCallLicenseGate $payloadModule)) {
                $errors.Add("ZTool.code::.cctor must not call ZTool.License.LicenseGate::IsLicensed(); it runs before Program.Main WinForms startup.")
            }

            $programGate = Test-ProgramMainHasFailClosedLicenseGate $payloadModule
            if (-not $programGate.IsFailClosed) {
                $errors.Add("ZTool.Program::Main does not fail closed on ZTool.License.LicenseGate::IsLicensed() before Application.Run (has license store=$($programGate.HasLicenseStore), gate count=$($programGate.GateCount), run index=$($programGate.RunIndex)).")
            }

            foreach ($autoConnectError in (Test-FrmmainSolidWorksLaunchAutoConnect $payloadModule)) {
                $errors.Add("Encrypted payload SolidWorks launch auto-connect is missing: $autoConnectError")
            }

            foreach ($legacyChecklicError in (Test-LegacyChecklicTimerDisabled $payloadModule)) {
                $errors.Add("Encrypted payload legacy license timer is unsafe: $legacyChecklicError")
            }

            foreach ($method in @(
                @{ Type = 'ZTool.Frmmain'; Name = '_checkupdate_ExecuteEvent' },
                @{ Type = 'ZTool.Frmmain'; Name = '_Lambda$__88' },
                @{ Type = 'ZTool.Frmmain'; Name = '_Lambda$__119' },
                @{ Type = 'ZTool.CheckUpdate'; Name = 'getinfo' },
                @{ Type = 'ZTool.CheckUpdate'; Name = 'updateprocess' },
                @{ Type = 'ZTool.CheckUpdate'; Name = 'openupdater' }
            )) {
                if (-not (Test-DnlibReturnsVoid $payloadModule $method.Type $method.Name)) {
                    $errors.Add("$($method.Type)::$($method.Name) is not disabled in the encrypted payload.")
                }
            }

            $checkUpdateShowHits = Test-NoCheckUpdateShowCall $payloadModule
            foreach ($hit in $checkUpdateShowHits) {
                $errors.Add("Encrypted payload can still show CheckUpdate via $hit.")
            }

            $winFormsStartupErrors = Test-WinFormsStartupBeforeProgramLicenseGate $payloadModule
            foreach ($winFormsStartupError in $winFormsStartupErrors) {
                $errors.Add("Encrypted payload WinForms startup order is unsafe: $winFormsStartupError")
            }

            $transferPatch = Test-RegistrationTransferUsesOwnedDeactivation $payloadModule
            if (-not $transferPatch.UsesOwnedDeactivation) {
                $errors.Add("ZTool.FrmRg::Button2_Click is not routed to ZTool.License.LicenseGate::DeactivateWithPassword.")
            }
            foreach ($legacyCall in $transferPatch.LegacyCalls) {
                $errors.Add("ZTool.FrmRg::Button2_Click still calls legacy registration transfer API: $legacyCall")
            }
        } finally {
            $payloadModule.Dispose()
        }
    } finally {
        Remove-Item -LiteralPath $payloadTemp -Force -ErrorAction SilentlyContinue
    }
} catch {
    $errors.Add("Cannot inspect ZTool.exe encrypted payload license gate: $($_.Exception.Message)")
}

try {
    $addinModule = [dnlib.DotNet.ModuleDefMD]::Load((Join-Path $root 'ZTool.dll'))
    try {
        foreach ($assemblyRefError in (Test-NoTokenSizedPublicKeyAssemblyRefs $addinModule 'ZTool.dll SolidWorks add-in')) {
            $errors.Add($assemblyRefError)
        }

        foreach ($licenseRefError in (Test-LicenseAssemblyReferencesUsePublicKeyToken $addinModule 'ZTool.dll SolidWorks add-in' $expectedForkToken $false)) {
            $errors.Add($licenseRefError)
        }

        $resourceErrors = Test-SolidWorksAddInImageResourcesEmbedded $addinModule
        foreach ($resourceError in $resourceErrors) {
            $errors.Add("ZTool.dll SolidWorks toolbar image resource is not embedded correctly: $resourceError")
        }

        $addinGate = Test-SolidWorksAddInLicenseBoundary $addinModule
        if ($addinGate.Checked -le 0) {
            $errors.Add("ZTool.dll SolidWorks add-in gate did not find any public entrypoints to verify.")
        }

        foreach ($methodName in $addinGate.PerCommandGateCalls) {
            $errors.Add("ZTool.dll SolidWorks add-in command must not show activation/demo; license gate belongs to ZTool.exe startup only: $methodName calls ZTool.License.LicenseGate::IsLicensed().")
        }
    } finally {
        $addinModule.Dispose()
    }
} catch {
    $errors.Add("Cannot inspect ZTool.dll SolidWorks add-in license gate: $($_.Exception.Message)")
}

try {
    $updaterName = [System.Reflection.AssemblyName]::GetAssemblyName((Join-Path $root 'ZTool Updater.exe')).Name
    if ($updaterName -ne 'ZTool.UpdateDisabled') {
        $errors.Add("ZTool Updater.exe is not the disabled-update stub.")
    }
} catch {
    $errors.Add("Cannot read ZTool Updater.exe assembly metadata: $($_.Exception.Message)")
}

try {
    $deactivateName = [System.Reflection.AssemblyName]::GetAssemblyName((Join-Path $root 'ZTool License Deactivate.exe')).Name
    if ($deactivateName -ne 'ZTool License Deactivate') {
        $errors.Add("ZTool License Deactivate.exe is not the deactivation utility.")
    }
} catch {
    $errors.Add("Cannot read ZTool License Deactivate.exe assembly metadata: $($_.Exception.Message)")
}

if ($errors.Count -gt 0) {
    [pscustomobject]@{
        Status = 'fail'
        Errors = $errors
    } | ConvertTo-Json -Depth 6
    exit 1
}

[pscustomobject]@{
    Status = 'ok'
    PackageRoot = $root
} | ConvertTo-Json -Depth 6
