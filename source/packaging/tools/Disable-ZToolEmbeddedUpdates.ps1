param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,
    [string]$SnkPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FullPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Get-DnlibPath {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $candidates = @(
        (Join-Path $repoRoot '_archive\_reverse\packages\dnlib\lib\net45\dnlib.dll'),
        (Join-Path $repoRoot '_archive\_reverse\packages\dnlib\lib\netstandard2.0\dnlib.dll')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    throw 'dnlib.dll was not found.'
}

function Ensure-DnlibLoaded {
    if ('dnlib.DotNet.ModuleDefMD' -as [type]) {
        return
    }

    Add-Type -Path (Get-DnlibPath)
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

function ConvertTo-ZToolPayloadResource([byte[]]$Payload) {
    $base64 = [Convert]::ToBase64String($Payload)
    $utf8Bom = [System.Text.UTF8Encoding]::new($true)
    $plain = [byte[]](@($utf8Bom.GetPreamble()) + @($utf8Bom.GetBytes($base64)))

    $des = [System.Security.Cryptography.DES]::Create()
    $des.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $des.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $des.Key = [byte[]](0x21,0x1B,0x53,0x5B,0x11,0x12,0x2D,0x4C)
    $des.IV = [byte[]](0x35,0x27,0x13,0x26,0x63,0x16,0x2F,0x34)
    $encryptor = $des.CreateEncryptor()
    try {
        $encryptor.TransformFinalBlock($plain, 0, $plain.Length)
    } finally {
        $encryptor.Dispose()
        $des.Dispose()
    }
}

function Get-Method([dnlib.DotNet.ModuleDef]$Module, [string]$TypeName, [string]$MethodName) {
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

function Get-Field([dnlib.DotNet.ModuleDef]$Module, [string]$TypeName, [string]$FieldName) {
    $type = $Module.Find($TypeName, $true)
    if ($null -eq $type) {
        throw "Type not found: $TypeName"
    }

    foreach ($field in $type.Fields) {
        if ([string]$field.Name -eq $FieldName) {
            return $field
        }
    }

    throw "Field not found: $TypeName::$FieldName"
}

function Get-NextNonNopInstructionIndex($Instructions, [int]$StartIndex) {
    for ($i = $StartIndex; $i -lt $Instructions.Count; $i++) {
        if ($Instructions[$i].OpCode -ne [dnlib.DotNet.Emit.OpCodes]::Nop) {
            return $i
        }
    }

    return -1
}

function Set-MethodReturnFalse([dnlib.DotNet.ModuleDef]$Module, [string]$TypeName, [string]$MethodName) {
    $method = Get-Method $Module $TypeName $MethodName
    $method.Body.ExceptionHandlers.Clear()
    $method.Body.Variables.Clear()
    $method.Body.Instructions.Clear()
    $method.Body.Instructions.Add([dnlib.DotNet.Emit.OpCodes]::Ldc_I4_0.ToInstruction())
    $method.Body.Instructions.Add([dnlib.DotNet.Emit.OpCodes]::Ret.ToInstruction())
    $method.Body.MaxStack = 1
}

function Set-MethodReturnVoid([dnlib.DotNet.ModuleDef]$Module, [string]$TypeName, [string]$MethodName) {
    $method = Get-Method $Module $TypeName $MethodName
    $method.Body.ExceptionHandlers.Clear()
    $method.Body.Variables.Clear()
    $method.Body.Instructions.Clear()
    $method.Body.Instructions.Add([dnlib.DotNet.Emit.OpCodes]::Ret.ToInstruction())
    $method.Body.MaxStack = 0
}

function Set-MethodReturnString([dnlib.DotNet.ModuleDef]$Module, [string]$TypeName, [string]$MethodName, [string]$Value) {
    $method = Get-Method $Module $TypeName $MethodName
    $method.Body.ExceptionHandlers.Clear()
    $method.Body.Variables.Clear()
    $method.Body.Instructions.Clear()
    $method.Body.Instructions.Add([dnlib.DotNet.Emit.OpCodes]::Ldstr.ToInstruction($Value))
    $method.Body.Instructions.Add([dnlib.DotNet.Emit.OpCodes]::Ret.ToInstruction())
    $method.Body.MaxStack = 1
}

function Disable-StartTypeUpdateWindow([dnlib.DotNet.ModuleDef]$Module) {
    $method = Get-Method $Module 'ZTool.MyapplicationContext' '.ctor'
    $instructions = $method.Body.Instructions
    $patched = 0

    for ($i = 0; $i -lt $instructions.Count; $i++) {
        $operand = $instructions[$i].Operand -as [dnlib.DotNet.IMethod]
        if ($null -eq $operand -or [string]$operand.Name -ne 'get_CheckUpdate') {
            continue
        }

        for ($j = [Math]::Max(0, $i - 1); $j -le [Math]::Min($instructions.Count - 1, $i + 1); $j++) {
            $instructions[$j] = [dnlib.DotNet.Emit.OpCodes]::Nop.ToInstruction()
        }
        $patched++
    }

    if ($patched -eq 0) {
        throw 'ZTool.MyapplicationContext::.ctor did not contain a CheckUpdate startup call.'
    }

    return $patched
}

function Move-WinFormsStartupBeforeLicenseGate([dnlib.DotNet.ModuleDef]$Module) {
    $method = Get-Method $Module 'ZTool.Program' 'Main'
    $instructions = $method.Body.Instructions
    $setCompatibleTextRenderingDefault = $null
    $enableVisualStyles = $null
    $hasEarlySetCompatibleTextRenderingDefault = $false
    $disabledLateSetCompatibleTextRenderingDefault = 0

    for ($i = 0; $i -lt $instructions.Count; $i++) {
        $operand = $instructions[$i].Operand -as [dnlib.DotNet.IMethod]
        if ($null -eq $operand) {
            continue
        }

        $fullName = [string]$operand.FullName
        if ($fullName -eq 'System.Void System.Windows.Forms.Application::EnableVisualStyles()') {
            $enableVisualStyles = $operand
            continue
        }

        if ($fullName -ne 'System.Void System.Windows.Forms.Application::SetCompatibleTextRenderingDefault(System.Boolean)') {
            continue
        }

        $setCompatibleTextRenderingDefault = $operand
        if ($i -le 6) {
            $hasEarlySetCompatibleTextRenderingDefault = $true
            continue
        }

        if ($i -gt 0) {
            $instructions[$i - 1] = [dnlib.DotNet.Emit.OpCodes]::Nop.ToInstruction()
        }

        $instructions[$i] = [dnlib.DotNet.Emit.OpCodes]::Nop.ToInstruction()
        $disabledLateSetCompatibleTextRenderingDefault++
    }

    if ($null -eq $setCompatibleTextRenderingDefault) {
        throw 'ZTool.Program::Main did not contain Application.SetCompatibleTextRenderingDefault.'
    }
    if ($null -eq $enableVisualStyles) {
        throw 'ZTool.Program::Main did not contain Application.EnableVisualStyles.'
    }

    if (-not $hasEarlySetCompatibleTextRenderingDefault) {
        $insertIndex = 1
        $startupInstructions = @(
            [dnlib.DotNet.Emit.OpCodes]::Call.ToInstruction($enableVisualStyles),
            [dnlib.DotNet.Emit.OpCodes]::Nop.ToInstruction(),
            [dnlib.DotNet.Emit.OpCodes]::Ldc_I4_0.ToInstruction(),
            [dnlib.DotNet.Emit.OpCodes]::Call.ToInstruction($setCompatibleTextRenderingDefault),
            [dnlib.DotNet.Emit.OpCodes]::Nop.ToInstruction()
        )

        for ($j = 0; $j -lt $startupInstructions.Count; $j++) {
            $instructions.Insert($insertIndex + $j, $startupInstructions[$j])
        }
    }

    return "moved-before-ZTool.code early=$(-not $hasEarlySetCompatibleTextRenderingDefault) late-SetCompatibleTextRenderingDefault-nopped=$disabledLateSetCompatibleTextRenderingDefault"
}

function Get-ReferencedMethod([dnlib.DotNet.ModuleDef]$Module, [string]$FullName) {
    foreach ($type in $Module.GetTypes()) {
        foreach ($method in $type.Methods) {
            if (-not $method.HasBody) {
                continue
            }

            foreach ($instruction in $method.Body.Instructions) {
                $operand = $instruction.Operand -as [dnlib.DotNet.IMethod]
                if ($null -ne $operand -and [string]$operand.FullName -eq $FullName) {
                    return $operand
                }
            }
        }
    }

    throw "Referenced method not found: $FullName"
}

function Get-FirstReferencedMethodByName([dnlib.DotNet.ModuleDef]$Module, [string]$MethodName, [string]$DeclaringTypeName) {
    foreach ($type in $Module.GetTypes()) {
        foreach ($method in $type.Methods) {
            if (-not $method.HasBody) {
                continue
            }

            foreach ($instruction in $method.Body.Instructions) {
                $operand = $instruction.Operand -as [dnlib.DotNet.IMethod]
                if ($null -ne $operand -and [string]$operand.Name -eq $MethodName -and [string]$operand.DeclaringType.FullName -eq $DeclaringTypeName) {
                    return $operand
                }
            }
        }
    }

    throw "Referenced method not found: $DeclaringTypeName::$MethodName"
}

function Get-LicenseGateIsLicensedReference([dnlib.DotNet.ModuleDef]$Module, [string]$LicenseDllPath) {
    foreach ($type in $Module.GetTypes()) {
        foreach ($method in $type.Methods) {
            if (-not $method.HasBody) {
                continue
            }

            foreach ($instruction in $method.Body.Instructions) {
                $operand = $instruction.Operand -as [dnlib.DotNet.IMethod]
                if ($null -ne $operand -and [string]$operand.FullName -eq 'System.Boolean ZTool.License.LicenseGate::IsLicensed()') {
                    return $operand
                }
            }
        }
    }

    if (-not (Test-Path -LiteralPath $LicenseDllPath -PathType Leaf)) {
        throw "ZTool.License.dll not found while creating a license gate reference: $LicenseDllPath"
    }

    $assemblyName = [System.Reflection.AssemblyName]::GetAssemblyName($LicenseDllPath)
    $publicKeyTokenBytes = [byte[]]$assemblyName.GetPublicKeyToken()
    if ($null -eq $publicKeyTokenBytes -or $publicKeyTokenBytes.Length -ne 8) {
        throw "ZTool.License.dll has an invalid public key token while creating a license gate reference: $LicenseDllPath"
    }

    $assemblyRef = [dnlib.DotNet.AssemblyRefUser]::new(
        [dnlib.DotNet.UTF8String]$assemblyName.Name,
        $assemblyName.Version,
        [dnlib.DotNet.PublicKeyToken]::new($publicKeyTokenBytes),
        [dnlib.DotNet.UTF8String]$assemblyName.CultureName)
    $assemblyRef.HasPublicKey = $false
    $typeRef = [dnlib.DotNet.TypeRefUser]::new(
        $Module,
        [dnlib.DotNet.UTF8String]'ZTool.License',
        [dnlib.DotNet.UTF8String]'LicenseGate',
        $assemblyRef)
    $isLicensedSig = [dnlib.DotNet.MethodSig]::CreateStatic($Module.CorLibTypes.Boolean)

    return [dnlib.DotNet.MemberRefUser]::new(
        $Module,
        [dnlib.DotNet.UTF8String]'IsLicensed',
        $isLicensedSig,
        $typeRef)
}

function Get-OriginalAssemblyRefPublicKeys([string]$OriginalAssemblyPath) {
    $publicKeys = @{}
    if (-not (Test-Path -LiteralPath $OriginalAssemblyPath -PathType Leaf)) {
        return $publicKeys
    }

    $originalModule = [dnlib.DotNet.ModuleDefMD]::Load($OriginalAssemblyPath)
    try {
        foreach ($assemblyRef in $originalModule.GetAssemblyRefs()) {
            $publicKey = $assemblyRef.PublicKeyOrToken
            $publicKeyText = [string]$publicKey
            if ($assemblyRef.HasPublicKey -and
                $null -ne $publicKey -and
                -not [string]::IsNullOrWhiteSpace($publicKeyText) -and
                $publicKeyText.Length -gt 16) {
                $publicKeys[[string]$assemblyRef.Name] = [dnlib.DotNet.PublicKey]::new($publicKeyText)
            }
        }
    } finally {
        $originalModule.Dispose()
    }

    return $publicKeys
}

function Repair-TokenSizedPublicKeyAssemblyRefs([dnlib.DotNet.ModuleDef]$Module, [hashtable]$OriginalPublicKeys) {
    $patched = New-Object System.Collections.Generic.List[string]
    foreach ($assemblyRef in $Module.GetAssemblyRefs()) {
        if ($assemblyRef.Name -eq 'ZTool.License') {
            $newLicenseTokenBytes = New-Object byte[] 8
            $newLicenseTokenBytes[0] = 0x60
            $newLicenseTokenBytes[1] = 0x91
            $newLicenseTokenBytes[2] = 0x76
            $newLicenseTokenBytes[3] = 0xc1
            $newLicenseTokenBytes[4] = 0x09
            $newLicenseTokenBytes[5] = 0x62
            $newLicenseTokenBytes[6] = 0xae
            $newLicenseTokenBytes[7] = 0xcc
            
            $assemblyRef.PublicKeyOrToken = [dnlib.DotNet.PublicKeyToken]::new($newLicenseTokenBytes)
            $assemblyRef.HasPublicKey = $false
            $patched.Add("ZTool.License reference updated to rotated token")
            continue
        }

        $publicKeyOrToken = [string]$assemblyRef.PublicKeyOrToken
        if (-not $assemblyRef.HasPublicKey -or
            [string]::IsNullOrWhiteSpace($publicKeyOrToken) -or
            $publicKeyOrToken.Length -ne 16 -or
            $publicKeyOrToken -notmatch '^[0-9a-fA-F]{16}$') {
            continue
        }

        $name = [string]$assemblyRef.Name
        if ($OriginalPublicKeys.ContainsKey($name)) {
            $assemblyRef.PublicKeyOrToken = $OriginalPublicKeys[$name]
            $assemblyRef.HasPublicKey = $true
            $patched.Add("$name restored-original-public-key")
        } else {
            $assemblyRef.PublicKeyOrToken = [dnlib.DotNet.PublicKeyToken]::new($publicKeyOrToken)
            $assemblyRef.HasPublicKey = $false
            $patched.Add("$name converted-to-public-key-token")
        }
    }

    return $patched
}

function Reset-CodeStaticConstructorLicenseGate([dnlib.DotNet.ModuleDef]$Module) {
    $method = Get-Method $Module 'ZTool.code' '.cctor'
    $instructions = $method.Body.Instructions
    $canRunField = Get-Field $Module 'ZTool.code' 'canrun'
    $patched = 0

    for ($i = 0; $i -lt $instructions.Count; $i++) {
        $methodOperand = $instructions[$i].Operand -as [dnlib.DotNet.IMethod]
        if ($null -eq $methodOperand -or [string]$methodOperand.FullName -ne 'System.Boolean ZTool.License.LicenseGate::IsLicensed()') {
            continue
        }

        $storeIndex = Get-NextNonNopInstructionIndex $instructions ($i + 1)
        if ($storeIndex -lt 0) {
            continue
        }

        $fieldOperand = $instructions[$storeIndex].Operand -as [dnlib.DotNet.IField]
        if ($instructions[$storeIndex].OpCode -ne [dnlib.DotNet.Emit.OpCodes]::Stsfld -or
            $null -eq $fieldOperand -or
            [string]$fieldOperand.FullName -ne [string]$canRunField.FullName) {
            continue
        }

        $instructions[$i] = [dnlib.DotNet.Emit.OpCodes]::Ldc_I4_0.ToInstruction()
        $patched++
    }

    if ($patched -eq 0) {
        return 'ZTool.code::.cctor license gate already absent'
    }

    return "ZTool.code::.cctor license gate reset-to-false patched=$patched"
}

function Patch-ProgramMainLicenseGate([dnlib.DotNet.ModuleDef]$Module, [string]$LicenseDllPath) {
    $method = Get-Method $Module 'ZTool.Program' 'Main'
    $instructions = $method.Body.Instructions
    $canRunField = Get-Field $Module 'ZTool.code' 'canrun'
    $isLicensed = Get-LicenseGateIsLicensedReference $Module $LicenseDllPath

    $alreadyPatched = $false
    foreach ($instruction in $instructions) {
        $methodOperand = $instruction.Operand -as [dnlib.DotNet.IMethod]
        if ($null -ne $methodOperand -and [string]$methodOperand.FullName -eq 'System.Boolean ZTool.License.LicenseGate::IsLicensed()') {
            $alreadyPatched = $true
            break
        }
    }

    if ($alreadyPatched) {
        return 'ZTool.Program::Main direct LicenseGate fail-closed gate already present'
    }

    $runIndex = -1
    $contextIndex = -1
    $retInstruction = $null

    for ($i = 0; $i -lt $instructions.Count; $i++) {
        $methodOperand = $instructions[$i].Operand -as [dnlib.DotNet.IMethod]
        if ($null -ne $methodOperand) {
            $fullName = [string]$methodOperand.FullName
            if ($fullName -eq 'System.Void System.Windows.Forms.Application::Run(System.Windows.Forms.ApplicationContext)') {
                $runIndex = $i
            }
            if ($fullName -eq 'System.Void ZTool.MyapplicationContext::.ctor()') {
                $contextIndex = $i
            }
        }

        if ($instructions[$i].OpCode -eq [dnlib.DotNet.Emit.OpCodes]::Ret) {
            $retInstruction = $instructions[$i]
        }
    }

    if ($runIndex -lt 0) {
        throw 'ZTool.Program::Main does not call Application.Run(ApplicationContext).'
    }
    if ($contextIndex -lt 0 -or $contextIndex -gt $runIndex) {
        throw 'ZTool.Program::Main does not construct ZTool.MyapplicationContext before Application.Run.'
    }
    if ($null -eq $retInstruction) {
        throw 'ZTool.Program::Main does not contain a return target.'
    }

    $assemblyLoadRef = $Module.Import([System.Reflection.Assembly].GetMethod('Load', [type[]]@([string])))

    $lateContinue = $instructions[$contextIndex]
    $instructions.Insert($contextIndex, [dnlib.DotNet.Emit.OpCodes]::Leave.ToInstruction($retInstruction))
    $instructions.Insert($contextIndex, [dnlib.DotNet.Emit.OpCodes]::Brtrue_S.ToInstruction($lateContinue))
    $instructions.Insert($contextIndex, [dnlib.DotNet.Emit.OpCodes]::Ldsfld.ToInstruction($canRunField))
    $instructions.Insert($contextIndex, [dnlib.DotNet.Emit.OpCodes]::Stsfld.ToInstruction($canRunField))
    $instructions.Insert($contextIndex, [dnlib.DotNet.Emit.OpCodes]::Call.ToInstruction($isLicensed))
    $instructions.Insert($contextIndex, [dnlib.DotNet.Emit.OpCodes]::Pop.ToInstruction())
    $instructions.Insert($contextIndex, [dnlib.DotNet.Emit.OpCodes]::Call.ToInstruction($assemblyLoadRef))
    $instructions.Insert($contextIndex, [dnlib.DotNet.Emit.OpCodes]::Ldstr.ToInstruction('ZTool.License, Version=1.1.0.0, Culture=neutral, PublicKeyToken=609176c10962aecc'))

    $method.Body.MaxStack = [Math]::Max($method.Body.MaxStack, 2)
    return 'ZTool.Program::Main direct LicenseGate fail-closed gate inserted=1'
}

function Patch-LegacyChecklicTimer([dnlib.DotNet.ModuleDef]$Module) {
    $ctor = Get-Method $Module 'ZTool.JDK.checklic' '.ctor'
    $elapsed = Get-Method $Module 'ZTool.JDK.checklic' 'tmr_Elapsed'
    $canRunField = Get-Field $Module 'ZTool.code' 'canrun'
    $objectCtor = Get-ReferencedMethod $Module 'System.Void System.Object::.ctor()'

    $patched = New-Object System.Collections.Generic.List[string]

    if (Test-MethodCalls $ctor 'System.Void System.Timers.Timer::.ctor(System.Double)') {
        $ctor.Body.Instructions.Clear()
        $ctor.Body.ExceptionHandlers.Clear()
        $ctor.Body.Variables.Clear()
        $ctor.Body.Instructions.Add([dnlib.DotNet.Emit.OpCodes]::Ldarg_0.ToInstruction())
        $ctor.Body.Instructions.Add([dnlib.DotNet.Emit.OpCodes]::Call.ToInstruction($objectCtor))
        $ctor.Body.Instructions.Add([dnlib.DotNet.Emit.OpCodes]::Ldc_I4_1.ToInstruction())
        $ctor.Body.Instructions.Add([dnlib.DotNet.Emit.OpCodes]::Stsfld.ToInstruction($canRunField))
        $ctor.Body.Instructions.Add([dnlib.DotNet.Emit.OpCodes]::Ret.ToInstruction())
        $ctor.Body.MaxStack = [Math]::Max($ctor.Body.MaxStack, 1)
        $patched.Add('ZTool.JDK.checklic::.ctor no longer starts the legacy dongle timer')
    }

    if ((Test-MethodCalls $elapsed 'System.Boolean ZTool.JDK.Prog1::exit_g()') -or
        (Test-MethodCalls $elapsed 'System.Boolean ZTool.JDK.Prog2::exit_g()') -or
        (Test-MethodCalls $elapsed 'System.Boolean ZTool.SR::IsReg2(System.String,System.String&,System.String&)')) {
        $elapsed.Body.Instructions.Clear()
        $elapsed.Body.ExceptionHandlers.Clear()
        $elapsed.Body.Variables.Clear()
        $elapsed.Body.Instructions.Add([dnlib.DotNet.Emit.OpCodes]::Ldc_I4_1.ToInstruction())
        $elapsed.Body.Instructions.Add([dnlib.DotNet.Emit.OpCodes]::Stsfld.ToInstruction($canRunField))
        $elapsed.Body.Instructions.Add([dnlib.DotNet.Emit.OpCodes]::Ret.ToInstruction())
        $elapsed.Body.MaxStack = [Math]::Max($elapsed.Body.MaxStack, 1)
        $patched.Add('ZTool.JDK.checklic::tmr_Elapsed no longer resets canrun from the legacy dongle state')
    }

    if ($patched.Count -eq 0) {
        $patched.Add('ZTool.JDK.checklic legacy dongle timer already disabled')
    }

    return $patched
}

function Test-MethodCalls([dnlib.DotNet.MethodDef]$Method, [string]$FullName) {
    foreach ($instruction in $Method.Body.Instructions) {
        $operand = $instruction.Operand -as [dnlib.DotNet.IMethod]
        if ($null -ne $operand -and [string]$operand.FullName -eq $FullName) {
            return $true
        }
    }

    return $false
}

function Get-LastRetInstruction([dnlib.DotNet.MethodDef]$Method) {
    $instructions = $Method.Body.Instructions
    for ($i = $instructions.Count - 1; $i -ge 0; $i--) {
        if ($instructions[$i].OpCode -eq [dnlib.DotNet.Emit.OpCodes]::Ret) {
            return $instructions[$i]
        }
    }

    throw "Method does not contain a ret instruction: $($Method.FullName)"
}

function Insert-InstructionsBefore([dnlib.DotNet.MethodDef]$Method, [dnlib.DotNet.Emit.Instruction]$Target, [object[]]$NewInstructions) {
    $instructions = $Method.Body.Instructions
    $index = -1
    for ($i = 0; $i -lt $instructions.Count; $i++) {
        if ([object]::ReferenceEquals($instructions[$i], $Target)) {
            $index = $i
            break
        }
    }

    if ($index -lt 0) {
        throw "Target instruction was not found in $($Method.FullName)."
    }

    for ($i = 0; $i -lt $NewInstructions.Count; $i++) {
        $instructions.Insert($index + $i, $NewInstructions[$i])
    }
}

function New-FrmmainReceiverPresentInstructions(
    [dnlib.DotNet.IField]$ReceiverHwndField,
    [dnlib.DotNet.IMethod]$IntPtrFromInt32,
    [dnlib.DotNet.IMethod]$IntPtrEquals,
    [dnlib.DotNet.Emit.Instruction]$SkipTarget
) {
    return @(
        [dnlib.DotNet.Emit.OpCodes]::Ldsfld.ToInstruction($ReceiverHwndField),
        [dnlib.DotNet.Emit.OpCodes]::Ldc_I4_0.ToInstruction(),
        [dnlib.DotNet.Emit.OpCodes]::Call.ToInstruction($IntPtrFromInt32),
        [dnlib.DotNet.Emit.OpCodes]::Call.ToInstruction($IntPtrEquals),
        [dnlib.DotNet.Emit.OpCodes]::Brtrue.ToInstruction($SkipTarget)
    )
}

function New-FrmmainStartTypeZeroInstructions(
    [dnlib.DotNet.IField]$StartTypeField,
    [dnlib.DotNet.IMethod]$ToStringInt32,
    [dnlib.DotNet.IMethod]$CompareString,
    [dnlib.DotNet.Emit.Instruction]$SkipTarget
) {
    return @(
        [dnlib.DotNet.Emit.OpCodes]::Ldsfld.ToInstruction($StartTypeField),
        [dnlib.DotNet.Emit.OpCodes]::Ldc_I4_0.ToInstruction(),
        [dnlib.DotNet.Emit.OpCodes]::Call.ToInstruction($ToStringInt32),
        [dnlib.DotNet.Emit.OpCodes]::Ldc_I4_0.ToInstruction(),
        [dnlib.DotNet.Emit.OpCodes]::Call.ToInstruction($CompareString),
        [dnlib.DotNet.Emit.OpCodes]::Ldc_I4_0.ToInstruction(),
        [dnlib.DotNet.Emit.OpCodes]::Ceq.ToInstruction(),
        [dnlib.DotNet.Emit.OpCodes]::Brfalse.ToInstruction($SkipTarget)
    )
}

function New-FrmmainConnectInstructions([dnlib.DotNet.IMethod]$ConnectMethod) {
    return @(
        [dnlib.DotNet.Emit.OpCodes]::Ldarg_0.ToInstruction(),
        [dnlib.DotNet.Emit.OpCodes]::Ldnull.ToInstruction(),
        [dnlib.DotNet.Emit.OpCodes]::Ldnull.ToInstruction(),
        [dnlib.DotNet.Emit.OpCodes]::Callvirt.ToInstruction($ConnectMethod),
        [dnlib.DotNet.Emit.OpCodes]::Nop.ToInstruction()
    )
}

function Patch-FrmmainSolidWorksLaunchAutoConnect([dnlib.DotNet.ModuleDef]$Module) {
    $connectFullName = 'System.Void ZTool.Frmmain::_ConnectSW_ExecuteEvent(System.Object,RibbonLib.Controls.Events.ExecuteEventArgs)'
    $loadMethod = Get-Method $Module 'ZTool.Frmmain' 'Frmmain_Load'
    $bringToFrontMethod = Get-Method $Module 'ZTool.Frmmain' 'BringToFrontSafely'

    $receiverHwndField = Get-Field $Module 'ZTool.code' 'Receiver_hWnd'
    $startTypeField = Get-Field $Module 'ZTool.Program' 'StartType'
    $openidField = Get-Field $Module 'ZTool.Frmmain' 'openid'
    $connectMethod = Get-Method $Module 'ZTool.Frmmain' '_ConnectSW_ExecuteEvent'

    $intPtrFromInt32 = Get-ReferencedMethod $Module 'System.IntPtr System.IntPtr::op_Explicit(System.Int32)'
    $intPtrEquals = Get-ReferencedMethod $Module 'System.Boolean System.IntPtr::op_Equality(System.IntPtr,System.IntPtr)'
    $toStringInt32 = Get-ReferencedMethod $Module 'System.String Microsoft.VisualBasic.CompilerServices.Conversions::ToString(System.Int32)'
    $compareString = Get-ReferencedMethod $Module 'System.Int32 Microsoft.VisualBasic.CompilerServices.Operators::CompareString(System.String,System.String,System.Boolean)'

    $patched = New-Object System.Collections.Generic.List[string]

    if (-not (Test-MethodCalls $loadMethod $connectFullName)) {
        $ret = Get-LastRetInstruction $loadMethod
        $newInstructions = @() +
            (New-FrmmainReceiverPresentInstructions $receiverHwndField $intPtrFromInt32 $intPtrEquals $ret) +
            (New-FrmmainStartTypeZeroInstructions $startTypeField $toStringInt32 $compareString $ret) +
            (New-FrmmainConnectInstructions $connectMethod)

        Insert-InstructionsBefore $loadMethod $ret $newInstructions
        $loadMethod.Body.MaxStack = [Math]::Max($loadMethod.Body.MaxStack, 3)
        $patched.Add('ZTool.Frmmain::Frmmain_Load auto-connects StartType=0 SolidWorks launches')
    }

    if (-not (Test-MethodCalls $bringToFrontMethod $connectFullName)) {
        $ret = Get-LastRetInstruction $bringToFrontMethod
        $newInstructions = @(
            [dnlib.DotNet.Emit.OpCodes]::Ldarg_0.ToInstruction(),
            [dnlib.DotNet.Emit.OpCodes]::Ldfld.ToInstruction($openidField),
            [dnlib.DotNet.Emit.OpCodes]::Ldstr.ToInstruction('1000'),
            [dnlib.DotNet.Emit.OpCodes]::Ldc_I4_0.ToInstruction(),
            [dnlib.DotNet.Emit.OpCodes]::Call.ToInstruction($compareString),
            [dnlib.DotNet.Emit.OpCodes]::Ldc_I4_0.ToInstruction(),
            [dnlib.DotNet.Emit.OpCodes]::Ceq.ToInstruction(),
            [dnlib.DotNet.Emit.OpCodes]::Brfalse.ToInstruction($ret)
        ) +
            (New-FrmmainReceiverPresentInstructions $receiverHwndField $intPtrFromInt32 $intPtrEquals $ret) +
            (New-FrmmainConnectInstructions $connectMethod)

        Insert-InstructionsBefore $bringToFrontMethod $ret $newInstructions
        $bringToFrontMethod.Body.MaxStack = [Math]::Max($bringToFrontMethod.Body.MaxStack, 3)
        $patched.Add('ZTool.Frmmain::BringToFrontSafely reconnects existing StartType=0 SolidWorks commands')
    }

    if ($patched.Count -eq 0) {
        $patched.Add('ZTool.Frmmain SolidWorks launch auto-connect already present')
    }

    return $patched
}

function Test-MethodAlreadyCallsLicenseGate([dnlib.DotNet.MethodDef]$Method) {
    foreach ($instruction in $Method.Body.Instructions) {
        $operand = $instruction.Operand -as [dnlib.DotNet.IMethod]
        if ($null -ne $operand -and [string]$operand.FullName -eq 'System.Boolean ZTool.License.LicenseGate::IsLicensed()') {
            return $true
        }
    }

    return $false
}

function Add-MethodEntryLicenseGate([dnlib.DotNet.MethodDef]$Method, [dnlib.DotNet.IMethod]$IsLicensed) {
    if (Test-MethodAlreadyCallsLicenseGate $Method) {
        return $false
    }

    $instructions = $Method.Body.Instructions
    if ($instructions.Count -eq 0) {
        throw "Method has an empty body: $($Method.FullName)"
    }

    $continue = $instructions[0]
    $returnType = [string]$Method.ReturnType.FullName

    if ($returnType -eq 'System.Void') {
        $instructions.Insert(0, [dnlib.DotNet.Emit.OpCodes]::Ret.ToInstruction())
        $instructions.Insert(0, [dnlib.DotNet.Emit.OpCodes]::Brtrue_S.ToInstruction($continue))
        $instructions.Insert(0, [dnlib.DotNet.Emit.OpCodes]::Call.ToInstruction($IsLicensed))
    } elseif ($returnType -eq 'System.Boolean') {
        $instructions.Insert(0, [dnlib.DotNet.Emit.OpCodes]::Ret.ToInstruction())
        $instructions.Insert(0, [dnlib.DotNet.Emit.OpCodes]::Ldc_I4_0.ToInstruction())
        $instructions.Insert(0, [dnlib.DotNet.Emit.OpCodes]::Brtrue_S.ToInstruction($continue))
        $instructions.Insert(0, [dnlib.DotNet.Emit.OpCodes]::Call.ToInstruction($IsLicensed))
    } else {
        throw "Unsupported method return type for license gate patch: $($Method.FullName) returns $returnType"
    }

    $Method.Body.MaxStack = [Math]::Max($Method.Body.MaxStack, 1)
    return $true
}

function Embed-SolidWorksAddInImageResources([dnlib.DotNet.ModuleDef]$Module, [string]$ResourceRoot) {
    if (-not (Test-Path -LiteralPath $ResourceRoot -PathType Container)) {
        throw "SolidWorks add-in resource root not found: $ResourceRoot"
    }

    $resourceNames = @(
        'ZTool.MainIconLarge_24.bmp',
        'ZTool.MainIconLarge_32.bmp',
        'ZTool.MainIconSmall_16.bmp',
        'ZTool.ToolbarLarge_24.bmp',
        'ZTool.ToolbarLarge_32.bmp',
        'ZTool.ToolbarSmall_16.bmp',
        'ZTool.flyGroupicon_16.png',
        'ZTool.flyGroupicon_24.png',
        'ZTool.flyGroupicon_32.png',
        'ZTool.flyGroupiconlist_16.png',
        'ZTool.flyGroupiconlist_24.png',
        'ZTool.flyGroupiconlist_32.png'
    )

    $patched = New-Object System.Collections.Generic.List[string]
    foreach ($resourceName in $resourceNames) {
        $fileName = $resourceName.Substring('ZTool.'.Length)
        $filePath = Join-Path $ResourceRoot $fileName
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            throw "SolidWorks add-in image resource file not found: $filePath"
        }

        $existingIndex = -1
        $attributes = [dnlib.DotNet.ManifestResourceAttributes]::Public
        for ($i = 0; $i -lt $Module.Resources.Count; $i++) {
            if ([string]$Module.Resources[$i].Name -eq $resourceName) {
                $existingIndex = $i
                $attributes = $Module.Resources[$i].Attributes
                break
            }
        }

        if ($existingIndex -lt 0) {
            throw "SolidWorks add-in linked image resource was not found in ZTool.dll: $resourceName"
        }

        $bytes = [System.IO.File]::ReadAllBytes($filePath)
        $Module.Resources[$existingIndex] = [dnlib.DotNet.EmbeddedResource]::new(
            [dnlib.DotNet.UTF8String]$resourceName,
            $bytes,
            $attributes)
        $patched.Add($resourceName)
    }

    return $patched
}

function Assert-SolidWorksAddInHasNoPerCommandLicenseGate([dnlib.DotNet.ModuleDef]$Module) {
    $type = $Module.Find('ZTool.SwAddin', $true)
    if ($null -eq $type) {
        throw 'Type not found: ZTool.SwAddin'
    }

    $violations = New-Object System.Collections.Generic.List[string]
    $checked = 0

    foreach ($method in $type.Methods) {
        if (-not $method.HasBody -or -not $method.IsPublic) {
            continue
        }

        $name = [string]$method.Name
        if (-not $name.StartsWith('Menu', [System.StringComparison]::Ordinal)) {
            continue
        }

        $checked++
        if (Test-MethodAlreadyCallsLicenseGate $method) {
            $violations.Add("ZTool.SwAddin::$name")
        }
    }

    if ($violations.Count -gt 0) {
        throw 'SolidWorks add-in per-command license gates would show activation/demo on every toolbar function: ' + ($violations -join ', ')
    }

    return "ZTool.SwAddin public Menu* handlers checked=$checked, per-command license gates=0"
}

function Patch-RegistrationTransferButton([dnlib.DotNet.ModuleDef]$Module) {
    $formType = $Module.Find('ZTool.FrmRg', $true)
    if ($null -eq $formType) {
        throw 'Type not found: ZTool.FrmRg'
    }

    $buttonMethod = Get-Method $Module 'ZTool.FrmRg' 'Button2_Click'
    $getPassword = Get-Method $Module 'ZTool.FrmRg' 'get_password'
    $textGetter = Get-FirstReferencedMethodByName $Module 'get_Text' 'System.Windows.Forms.TextBox'
    $environmentExit = Get-ReferencedMethod $Module 'System.Void System.Environment::Exit(System.Int32)'
    $isLicensed = Get-ReferencedMethod $Module 'System.Boolean ZTool.License.LicenseGate::IsLicensed()'

    $deactivateSig = [dnlib.DotNet.MethodSig]::CreateStatic($Module.CorLibTypes.Boolean, $Module.CorLibTypes.String)
    $deactivateMethod = [dnlib.DotNet.MemberRefUser]::new(
        $Module,
        [dnlib.DotNet.UTF8String]'DeactivateWithPassword',
        $deactivateSig,
        $isLicensed.DeclaringType)

    $buttonMethod.Body.ExceptionHandlers.Clear()
    $buttonMethod.Body.Variables.Clear()
    $buttonMethod.Body.Instructions.Clear()
    $buttonMethod.Body.MaxStack = 1

    $ret = [dnlib.DotNet.Emit.OpCodes]::Ret.ToInstruction()
    $buttonMethod.Body.Instructions.Add([dnlib.DotNet.Emit.OpCodes]::Ldarg_0.ToInstruction())
    $buttonMethod.Body.Instructions.Add([dnlib.DotNet.Emit.OpCodes]::Callvirt.ToInstruction($getPassword))
    $buttonMethod.Body.Instructions.Add([dnlib.DotNet.Emit.OpCodes]::Callvirt.ToInstruction($textGetter))
    $buttonMethod.Body.Instructions.Add([dnlib.DotNet.Emit.OpCodes]::Call.ToInstruction($deactivateMethod))
    $buttonMethod.Body.Instructions.Add([dnlib.DotNet.Emit.OpCodes]::Brfalse_S.ToInstruction($ret))
    $buttonMethod.Body.Instructions.Add([dnlib.DotNet.Emit.OpCodes]::Ldc_I4_0.ToInstruction())
    $buttonMethod.Body.Instructions.Add([dnlib.DotNet.Emit.OpCodes]::Call.ToInstruction($environmentExit))
    $buttonMethod.Body.Instructions.Add($ret)

    return 'ZTool.FrmRg::Button2_Click'
}

function Get-EmbeddedPayload([string]$ExePath, [string]$ResourceName) {
    $module = [dnlib.DotNet.ModuleDefMD]::Load($ExePath)
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

function Write-StrongNamedModule([dnlib.DotNet.ModuleDefMD]$Module, [string]$OutputPath, [dnlib.DotNet.StrongNameKey]$StrongNameKey) {
    $options = [dnlib.DotNet.Writer.ModuleWriterOptions]::new($Module)
    $options.Logger = [dnlib.DotNet.DummyLogger]::NoThrowInstance
    $options.MetadataOptions.Flags = $options.MetadataOptions.Flags -bor [dnlib.DotNet.Writer.MetadataFlags]::PreserveAll
    $options.InitializeStrongNameSigning($Module, $StrongNameKey)
    $Module.Write($OutputPath, $options)
}

$packageRootFull = Resolve-FullPath $PackageRoot
if (-not (Test-Path -LiteralPath $packageRootFull -PathType Container)) {
    throw "PackageRoot not found: $packageRootFull"
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if ([string]::IsNullOrWhiteSpace($SnkPath)) {
    $SnkPath = Join-Path $repoRoot '_archive\_reverse\prototype-resign\ZToolFork3.snk'
}
$snkFull = Resolve-FullPath $SnkPath
if (-not (Test-Path -LiteralPath $snkFull -PathType Leaf)) {
    throw "SNK not found: $snkFull"
}

Ensure-DnlibLoaded

$exePath = Join-Path $packageRootFull 'ZTool.exe'
if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    throw "ZTool.exe not found: $exePath"
}
$licenseDllPath = Join-Path $packageRootFull 'ZTool.License.dll'
$ztoolProtocolToken = '9EF1CBF0BCFAD9F118EA30863B1874'

$resourceName = 'ZTool.9eAd0SlNKphk.png'
$strongNameKey = [dnlib.DotNet.StrongNameKey]::new($snkFull)
$originalAddInPublicKeys = Get-OriginalAssemblyRefPublicKeys (Join-Path $repoRoot 'ZTool-original\ZTool.dll')
$payloadTemp = Join-Path ([System.IO.Path]::GetTempPath()) ("ztool-disable-update-payload-" + [guid]::NewGuid().ToString('N') + ".dll")
$payloadPatched = Join-Path ([System.IO.Path]::GetTempPath()) ("ztool-disable-update-payload-patched-" + [guid]::NewGuid().ToString('N') + ".dll")
$exePatched = Join-Path ([System.IO.Path]::GetTempPath()) ("ztool-disable-update-exe-" + [guid]::NewGuid().ToString('N') + ".exe")
$addinPatched = Join-Path ([System.IO.Path]::GetTempPath()) ("ztool-disable-update-addin-" + [guid]::NewGuid().ToString('N') + ".dll")
$payloadAssemblyRefsRepaired = @()
$outerAssemblyRefsRepaired = @()
$addinAssemblyRefsRepaired = @()

try {
    $payloadBytes = ConvertFrom-ZToolPayloadResource (Get-EmbeddedPayload $exePath $resourceName)
    [System.IO.File]::WriteAllBytes($payloadTemp, $payloadBytes)

    $payloadModule = [dnlib.DotNet.ModuleDefMD]::Load($payloadTemp)
    try {
        Set-MethodReturnFalse $payloadModule 'ZTool.Frmmain' 'haveupdate'
        foreach ($method in @(
            @{ Type = 'ZTool.Frmmain'; Name = '_checkupdate_ExecuteEvent' },
            @{ Type = 'ZTool.Frmmain'; Name = '_Lambda$__88' },
            @{ Type = 'ZTool.Frmmain'; Name = '_Lambda$__119' },
            @{ Type = 'ZTool.CheckUpdate'; Name = 'getinfo' },
            @{ Type = 'ZTool.CheckUpdate'; Name = 'updateprocess' },
            @{ Type = 'ZTool.CheckUpdate'; Name = 'openupdater' }
        )) {
            Set-MethodReturnVoid $payloadModule $method.Type $method.Name
        }
        $startupCallsPatched = Disable-StartTypeUpdateWindow $payloadModule
        $codeStaticConstructorPatched = Reset-CodeStaticConstructorLicenseGate $payloadModule
        Set-MethodReturnString $payloadModule 'ZTool.code' 'Getpkt' $ztoolProtocolToken
        $programMainLicenseGatePatched = Patch-ProgramMainLicenseGate $payloadModule $licenseDllPath
        $legacyChecklicPatched = @(Patch-LegacyChecklicTimer $payloadModule)
        $frmmainSolidWorksLaunchAutoConnectPatched = @(Patch-FrmmainSolidWorksLaunchAutoConnect $payloadModule)
        $registrationTransferPatched = Patch-RegistrationTransferButton $payloadModule
        $payloadAssemblyRefsRepaired = @(Repair-TokenSizedPublicKeyAssemblyRefs $payloadModule $originalAddInPublicKeys)
        Write-StrongNamedModule $payloadModule $payloadPatched $strongNameKey
    } finally {
        $payloadModule.Dispose()
    }

    $encryptedPatchedPayload = ConvertTo-ZToolPayloadResource ([System.IO.File]::ReadAllBytes($payloadPatched))

    $outerModule = [dnlib.DotNet.ModuleDefMD]::Load($exePath)
    try {
        $resourcePatched = $false
        for ($i = 0; $i -lt $outerModule.Resources.Count; $i++) {
            $embedded = $outerModule.Resources[$i] -as [dnlib.DotNet.EmbeddedResource]
            if ($null -eq $embedded -or [string]$embedded.Name -ne $resourceName) {
                continue
            }

            $outerModule.Resources[$i] = [dnlib.DotNet.EmbeddedResource]::new($embedded.Name, $encryptedPatchedPayload, $embedded.Attributes)
            $resourcePatched = $true
            break
        }

        if (-not $resourcePatched) {
            throw "Embedded resource not found while writing: $resourceName"
        }

        $outerAssemblyRefsRepaired = @(Repair-TokenSizedPublicKeyAssemblyRefs $outerModule $originalAddInPublicKeys)
        Write-StrongNamedModule $outerModule $exePatched $strongNameKey
    } finally {
        $outerModule.Dispose()
    }

    Copy-Item -LiteralPath $exePatched -Destination $exePath -Force

    $addinPath = Join-Path $packageRootFull 'ZTool.dll'
    if (-not (Test-Path -LiteralPath $addinPath -PathType Leaf)) {
        throw "ZTool.dll not found: $addinPath"
    }

    $solidWorksAddInAudited = @()
    $solidWorksImageResourcesPatched = @()
    $addinModule = [dnlib.DotNet.ModuleDefMD]::Load($addinPath)
    try {
        $resourceRoot = Resolve-FullPath (Join-Path $PSScriptRoot '..\assets\ZTool.SolidWorks.AddIn\Resources')
        $solidWorksImageResourcesPatched = @(Embed-SolidWorksAddInImageResources $addinModule $resourceRoot)
        $solidWorksAddInAudited = @(Assert-SolidWorksAddInHasNoPerCommandLicenseGate $addinModule)
        $addinAssemblyRefsRepaired = @(Repair-TokenSizedPublicKeyAssemblyRefs $addinModule $originalAddInPublicKeys)
        Write-StrongNamedModule $addinModule $addinPatched $strongNameKey
    } finally {
        $addinModule.Dispose()
    }

    Copy-Item -LiteralPath $addinPatched -Destination $addinPath -Force

    $patchedItems = @(
        'ZTool.Frmmain::haveupdate',
        'ZTool.Frmmain::_checkupdate_ExecuteEvent',
        'ZTool.Frmmain::_Lambda$__88',
        'ZTool.Frmmain::_Lambda$__119',
        'ZTool.CheckUpdate::getinfo',
        'ZTool.CheckUpdate::updateprocess',
        'ZTool.CheckUpdate::openupdater',
        "ZTool.MyapplicationContext::.ctor CheckUpdate calls=$startupCallsPatched",
        $codeStaticConstructorPatched,
        "ZTool.code::Getpkt returns original SolidWorks IPC token $ztoolProtocolToken",
        $programMainLicenseGatePatched,
        "$registrationTransferPatched uses ZTool.License.LicenseGate::DeactivateWithPassword"
    ) + @($legacyChecklicPatched) +
        @($frmmainSolidWorksLaunchAutoConnectPatched) +
        @($solidWorksImageResourcesPatched | ForEach-Object { "$_ embedded" }) +
        @($solidWorksAddInAudited) +
        @($payloadAssemblyRefsRepaired | ForEach-Object { "payload assembly ref $_" }) +
        @($outerAssemblyRefsRepaired | ForEach-Object { "outer assembly ref $_" }) +
        @($addinAssemblyRefsRepaired | ForEach-Object { "addin assembly ref $_" })

    [pscustomobject]@{
        Status = 'ok'
        PackageRoot = $packageRootFull
        Patched = $patchedItems
    } | ConvertTo-Json -Depth 4
} finally {
    Remove-Item -LiteralPath $payloadTemp -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $payloadPatched -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $exePatched -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $addinPatched -Force -ErrorAction SilentlyContinue
}
