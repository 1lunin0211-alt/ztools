param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,
    [string]$SnkPath = '',
    [string]$OriginalAddInPath = '',
    [ValidateSet('Russian','English')]
    [string]$Language = 'Russian',
    [switch]$SkipLicenseGatePatch,
    [switch]$SkipLanguageSelectorPatch
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
    $moduleAssemblyVersion = $null
    if ($null -ne $Module.Assembly -and $null -ne $Module.Assembly.Version) {
        $moduleAssemblyVersion = $Module.Assembly.Version
    }
    
    $newLicenseTokenBytes = New-Object byte[] 8
    $newLicenseTokenBytes[0] = 0x60
    $newLicenseTokenBytes[1] = 0x91
    $newLicenseTokenBytes[2] = 0x76
    $newLicenseTokenBytes[3] = 0xc1
    $newLicenseTokenBytes[4] = 0x09
    $newLicenseTokenBytes[5] = 0x62
    $newLicenseTokenBytes[6] = 0xae
    $newLicenseTokenBytes[7] = 0xcc
    
    foreach ($assemblyRef in $Module.GetAssemblyRefs()) {
        # Check if name is the obfuscated ZTool name
        if ($assemblyRef.Name -eq 'ESYGdDVneyZGaacscwWoIlKTWklM') {
            $assemblyRef.Name = 'ZTool'
            if ($null -ne $moduleAssemblyVersion) {
                $assemblyRef.Version = $moduleAssemblyVersion
            }
            $assemblyRef.PublicKeyOrToken = [dnlib.DotNet.PublicKeyToken]::new($newLicenseTokenBytes)
            $assemblyRef.HasPublicKey = $false
            $patched.Add("Obfuscated assembly reference renamed to ZTool and token updated to rotated token")
            continue
        }

        if ($assemblyRef.Name -eq 'ZTool' -and $null -ne $moduleAssemblyVersion -and [string]$assemblyRef.Version -eq '0.0.0.0') {
            $assemblyRef.Version = $moduleAssemblyVersion
            $patched.Add("ZTool self/reference version updated from 0.0.0.0 to $moduleAssemblyVersion")
        }

        # Check if name is ZTool.License
        if ($assemblyRef.Name -eq 'ZTool.License') {
            $assemblyRef.PublicKeyOrToken = [dnlib.DotNet.PublicKeyToken]::new($newLicenseTokenBytes)
            $assemblyRef.HasPublicKey = $false
            $patched.Add("ZTool.License reference updated to rotated token")
            continue
        }
        
        # Check if token is the old token
        $tokenHex = ""
        if ($assemblyRef.PublicKeyOrToken -ne $null) {
            if ($assemblyRef.PublicKeyOrToken.Token -ne $null -and $assemblyRef.PublicKeyOrToken.Token.Data -ne $null) {
                $tokenHex = [BitConverter]::ToString($assemblyRef.PublicKeyOrToken.Token.Data).Replace("-", "").ToLowerInvariant()
            }
        }
        
        if ($tokenHex -eq '69848a58054312c2') {
            $assemblyRef.PublicKeyOrToken = [dnlib.DotNet.PublicKeyToken]::new($newLicenseTokenBytes)
            $assemblyRef.HasPublicKey = $false
            $patched.Add("$($assemblyRef.Name) token updated to rotated token (old token was 69848a58054312c2)")
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

    $existingAssemblyLoadRef = Get-FirstReferencedMethodByName $Module 'Load' 'System.Reflection.Assembly'
    $assemblyLoadSig = [dnlib.DotNet.MethodSig]::CreateStatic($existingAssemblyLoadRef.MethodSig.RetType, $Module.CorLibTypes.String)
    $assemblyLoadRef = [dnlib.DotNet.MemberRefUser]::new($Module, 'Load', $assemblyLoadSig, $existingAssemblyLoadRef.DeclaringType)

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
        [dnlib.DotNet.Emit.OpCodes]::Call.ToInstruction($ToStringInt32),
        [dnlib.DotNet.Emit.OpCodes]::Ldstr.ToInstruction('0'),
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

function Patch-HasShell([dnlib.DotNet.ModuleDef]$Module) {
    $type = $Module.Find('ZTool.code', $true)
    if ($null -eq $type) {
        throw 'Type ZTool.code not found.'
    }

    foreach ($method in $type.Methods) {
        if ([string]$method.Name -eq 'HasShell') {
            $method.Body.ExceptionHandlers.Clear()
            $method.Body.Variables.Clear()
            $method.Body.Instructions.Clear()
            $method.Body.Instructions.Add([dnlib.DotNet.Emit.OpCodes]::Ldc_I4_1.ToInstruction())
            $method.Body.Instructions.Add([dnlib.DotNet.Emit.OpCodes]::Ret.ToInstruction())
            $method.Body.MaxStack = 1
            return 'ZTool.code::HasShell patched to always return true'
        }
    }

    throw 'Method HasShell not found in ZTool.code.'
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

# .NET Reactor-obfuscated ZTool.dll cannot be round-trip-written by dnlib (the obfuscator
# emits malformed IL with null-target short branches that dnlib refuses to re-serialize).
# Therefore CJK byte-sequences inside ZTool.dll's metadata heaps (Constant.Value blobs +
# CustomAttribute blobs) must be replaced via length-preserving in-place byte patches.
#
# Each entry: original UTF-16LE / UTF-8 byte sequence (and language-specific replacement
# of identical length). For UTF-16LE template tokens the same string is *also* present in
# the payload IL as ldstr operands (handled by Get-StringMap), so EN/RU values here must
# match Get-StringMap so the payload's runtime string comparisons (template.Replace(...))
# stay in sync with ZTool.dll's local field constants.
function Get-ZToolDllCjkPatches([string]$Language) {
    if ($Language -eq 'English') {
        # 4-char and 6-char UTF-16LE replacements -- must align with Get-StringMap EN values
        $tplDN     = '$DN$'    # was $图号$
        $tplName   = '$NAME$'  # was $零件名称$
        $tplRev    = '$Rev'    # was $版本$
        $tokFile   = '<file_>' # was <磁盘文件名>
        $tokConf   = '<conf>'  # was <配置名称>
        # UTF-8 custom attribute values (lengths shown as bytes)
        $titleSuf  = 'SolidWorks Helper '                            # 18B -> was 高效辅助工具 (18B)
        $descAttr  = 'Provides a Vista-style file selection dialog   ' # 47B -> was 提供一个Vista样式的选择文件对话框 (47B)
        # VERSIONINFO UTF-16LE strings (each char = 2 bytes UTF-16LE)
        $vinfoSuff = 'later'  # 5 chars; was 及以上版本
        $vinfoTitle = 'Helper' # 6 chars; was 高效辅助工具
    } else {
        # Russian. Cyrillic chars are 2 bytes UTF-16LE, same width as ASCII or CJK.
        $tplDN     = '$НЧ$'    # was $图号$ (4 chars)
        $tplName   = '$ИмяД$'  # was $零件名称$ (6 chars)
        $tplRev    = '$Рев'    # was $版本$ (4 chars)
        $tokFile   = '<файл_>' # was <磁盘文件名> (7 chars)
        $tokConf   = '<конф>'  # was <配置名称> (6 chars)
        # UTF-8: Cyrillic = 2 bytes/char, ASCII = 1 byte/char
        # "Помощник  " = 8*2 + 2*1 = 18 bytes (matches 高效辅助工具 18B)
        $titleSuf  = 'Помощник  '
        # 47 bytes: 'Диалог выбора файла Vista     ' (each Cyrillic letter = 2B, ASCII = 1B)
        # Диалог(12)+space(1)+выбора(12)+space(1)+файла(10)+space(1)+Vista(5)+5spaces(5) = 47
        $descAttr  = 'Диалог выбора файла Vista     '
        # VERSIONINFO UTF-16LE strings
        $vinfoSuff = 'позже'   # 5 chars Cyrillic; was 及以上版本
        $vinfoTitle = 'Помощь' # 6 chars Cyrillic; was 高效辅助工具
    }

    $patches = New-Object 'System.Collections.Generic.List[hashtable]'
    $utf16le = [System.Text.Encoding]::Unicode
    $utf8    = [System.Text.UTF8Encoding]::new($false, $false)

    # NOTE: The first occurrence cluster of these template-token strings (offsets
    # 0x566c2, 0x566cc, 0x566da, 0x56c9b, 0x56cab) lies INSIDE the .NET #US heap and
    # is handled by Invoke-ZToolDllUsHeapCjkPatches (via the JSON translation table).
    # Likewise the two 0x5705b / 0x57739 strings are #US-heap entries, not VERSIONINFO.
    # Here we only patch the DUPLICATE copies that live in the #Blob heap (used by
    # Constant table entries for the const-field default values that are loaded by
    # the payload IL via ldsfld semantics through reflection).
    $patches.Add(@{ Offset = 0x00058465; Encoding = 'UTF16LE'; From = '$图号$';     To = $tplDN   })
    $patches.Add(@{ Offset = 0x0005846e; Encoding = 'UTF16LE'; From = '$零件名称$'; To = $tplName })
    $patches.Add(@{ Offset = 0x0005847b; Encoding = 'UTF16LE'; From = '$版本$';     To = $tplRev  })
    $patches.Add(@{ Offset = 0x00058560; Encoding = 'UTF16LE'; From = '<磁盘文件名>';To = $tokFile })
    $patches.Add(@{ Offset = 0x0005856f; Encoding = 'UTF16LE'; From = '<配置名称>'; To = $tokConf })

    # UTF-8 custom attribute blobs (AssemblyDescription, AssemblyTitle):
    $patches.Add(@{ Offset = 0x00058ad4; Encoding = 'UTF8'; From = '提供一个Vista样式的选择文件对话框'; To = $descAttr })
    $patches.Add(@{ Offset = 0x000590af; Encoding = 'UTF8'; From = '高效辅助工具';                  To = $titleSuf })

    return ,$patches
}

function Get-ZToolExeCjkPatches([string]$Language) {
    # ZTool.exe contains CJK in two regions:
    # 1) Assembly attribute custom-attribute blobs (AssemblyDescription "...Solidworks2012...",
    #    AssemblyTitle "SolidWorks高效辅助工具") - need readable EN/RU replacement (same byte length)
    # 2) UAC application manifest XML in .rsrc (Chinese XML comments in trustInfo/compatibility) -
    #    these are pure decoration; replace each CJK run with same-length spaces (blanks)
    if ($Language -eq 'English') {
        # 38 bytes; original = '适用于Solidworks2012及以上版本'
        $descFull = 'Used for SolidWorks 2012 and later    '
        # 28 bytes; original = 'SolidWorks高效辅助工具'
        $titleFull = 'SolidWorks Helper           '
        # VERSIONINFO UTF-16LE fragment replacements (each char = 2 bytes UTF-16LE)
        $vinfoPre = 'Use'    # 3 chars; was 适用于
        $vinfoSuff = 'later' # 5 chars; was 及以上版本
        $vinfoTitle = 'Helper' # 6 chars; was 高效辅助工具
        # .NET Reactor runtime error strings (in .text section, UTF-16LE)
        $rxCompileErr = 'CmpEr'  # 5 chars; was '编译错误！'
        $rxErr        = 'Er'      # 2 chars; was '错误'
    } else {
        # 38 bytes; 'Для SolidWorks 2012 и выше    ' (mix of Cyrillic and ASCII)
        $descFull = 'Для SolidWorks 2012 и выше    '
        # 28 bytes; 'SolidWorks Помощник ' (ascii + cyrillic + trailing space)
        $titleFull = 'SolidWorks Помощник '
        # VERSIONINFO UTF-16LE fragment replacements
        $vinfoPre = 'Для'    # 3 chars Cyrillic; was 适用于
        $vinfoSuff = 'позже' # 5 chars Cyrillic; was 及以上版本
        $vinfoTitle = 'Помощь' # 6 chars Cyrillic; was 高效辅助工具
        # .NET Reactor runtime error strings (in .text section, UTF-16LE)
        $rxCompileErr = 'Комп!'  # 5 chars; was '编译错误！'
        $rxErr        = 'Ош'     # 2 chars; was '错误'
    }

    $utf8 = [System.Text.UTF8Encoding]::new($false, $false)
    $utf16 = [System.Text.Encoding]::Unicode
    $entries = New-Object 'System.Collections.Generic.List[hashtable]'

    # Assembly attribute strings (length-preserving, UTF-8)
    $entries.Add(@{
        Kind = 'Attr'
        FromBytes = $utf8.GetBytes('适用于Solidworks2012及以上版本')
        ToBytes   = $utf8.GetBytes($descFull)
    })
    $entries.Add(@{
        Kind = 'Attr'
        FromBytes = $utf8.GetBytes('SolidWorks高效辅助工具')
        ToBytes   = $utf8.GetBytes($titleFull)
    })

    # VERSIONINFO Win32 resource strings (UTF-16LE in .rsrc) - file properties dialog
    $entries.Add(@{
        Kind = 'VInfo'
        FromBytes = $utf16.GetBytes('适用于')
        ToBytes   = $utf16.GetBytes($vinfoPre)
        Original  = '适用于 (utf-16le)'
    })
    $entries.Add(@{
        Kind = 'VInfo'
        FromBytes = $utf16.GetBytes('及以上版本')
        ToBytes   = $utf16.GetBytes($vinfoSuff)
        Original  = '及以上版本 (utf-16le)'
    })
    $entries.Add(@{
        Kind = 'VInfo'
        FromBytes = $utf16.GetBytes('高效辅助工具')
        ToBytes   = $utf16.GetBytes($vinfoTitle)
        Original  = '高效辅助工具 (utf-16le)'
    })

    # .NET Reactor runtime error strings embedded in the .text section (loader stub)
    $entries.Add(@{
        Kind = 'RuntimeErr'
        FromBytes = $utf16.GetBytes('编译错误！')
        ToBytes   = $utf16.GetBytes($rxCompileErr)
        Original  = '编译错误！ (utf-16le)'
    })
    $entries.Add(@{
        Kind = 'RuntimeErr'
        FromBytes = $utf16.GetBytes('错误')
        ToBytes   = $utf16.GetBytes($rxErr)
        Original  = '错误 (utf-16le)'
    })

    # UAC manifest XML comments - blank out each CJK run with spaces of equal byte length
    $manifestCjkRuns = @(
        '清单选项',
        '如果要更改',
        '用户帐户控制级别',
        '请用以下节点之一替换',
        '节点。',
        '指定',
        '节点将会禁用文件和注册表虚拟化。',
        '如果要利用文件和注册表虚拟化实现向后',
        '兼容性',
        '则删除',
        '此应用程序设计使用的所有',
        '版本的列表。',
        '将会自动选择最兼容的环境。',
        '如果应用程序设计使用',
        '请取消注释以下',
        '节点',
        '启用',
        '公共控件和对话框的主题',
        '和更高版本'
    )
    foreach ($run in $manifestCjkRuns) {
        $fromBytes = $utf8.GetBytes($run)
        $toBytes = New-Object byte[] $fromBytes.Length
        for ($i = 0; $i -lt $toBytes.Length; $i++) { $toBytes[$i] = 0x20 }  # ASCII space
        $entries.Add(@{ Kind = 'Manifest'; FromBytes = $fromBytes; ToBytes = $toBytes; Original = $run })
    }

    return ,$entries
}

function Invoke-ZToolExeBinaryStringPatches([string]$ExePath, [string]$Language) {
    if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) {
        throw "ZTool.exe not found for binary CJK patching: $ExePath"
    }

    $bytes = [System.IO.File]::ReadAllBytes($ExePath)
    $entries = Get-ZToolExeCjkPatches -Language $Language

    $totalReplacements = 0
    $report = New-Object 'System.Collections.Generic.List[string]'
    foreach ($e in $entries) {
        $from = [byte[]]$e.FromBytes
        $to   = [byte[]]$e.ToBytes
        if ($from.Length -ne $to.Length) {
            throw "ZTool.exe patch length mismatch: from=$($from.Length)B to=$($to.Length)B"
        }
        # Search the whole file (offsets shift after dnlib rewrite) and replace all matches.
        $occurrences = 0
        $i = 0
        while ($i -le ($bytes.Length - $from.Length)) {
            $match = $true
            for ($k = 0; $k -lt $from.Length; $k++) {
                if ($bytes[$i + $k] -ne $from[$k]) { $match = $false; break }
            }
            if ($match) {
                for ($k = 0; $k -lt $to.Length; $k++) {
                    $bytes[$i + $k] = $to[$k]
                }
                $occurrences++
                $totalReplacements++
                $i += $from.Length
            } else {
                $i++
            }
        }
        if ($occurrences -gt 0) {
            $orig = if ($e.ContainsKey('Original')) { [string]$e.Original } else { [System.Text.UTF8Encoding]::new($false, $false).GetString($from) }
            $report.Add(("{0} x{1}: '{2}'" -f $e.Kind, $occurrences, $orig))
        }
    }

    # Residual UTF-8 CJK scan
    $residualCjk = 0
    $i = 0
    while ($i -lt $bytes.Length - 2) {
        $b0 = $bytes[$i]
        if ($b0 -ge 0xE4 -and $b0 -le 0xE9 -and $bytes[$i+1] -ge 0x80 -and $bytes[$i+1] -le 0xBF -and $bytes[$i+2] -ge 0x80 -and $bytes[$i+2] -le 0xBF) {
            $residualCjk++
            $i += 3
        } else {
            $i++
        }
    }

    [System.IO.File]::WriteAllBytes($ExePath, $bytes)

    return @{
        TotalReplacements = $totalReplacements
        PatchDetails = $report
        ResidualUtf8CjkSequences = $residualCjk
    }
}

function Invoke-ZToolDllBinaryStringPatches([string]$DllPath, [string]$Language) {
    if (-not (Test-Path -LiteralPath $DllPath -PathType Leaf)) {
        throw "ZTool.dll not found for binary CJK patching: $DllPath"
    }

    $bytes = [System.IO.File]::ReadAllBytes($DllPath)
    $patches = Get-ZToolDllCjkPatches -Language $Language

    $applied = 0
    $report = New-Object 'System.Collections.Generic.List[string]'
    foreach ($p in $patches) {
        $offset = [int]$p.Offset
        $encName = [string]$p.Encoding
        $fromStr = [string]$p.From
        $toStr   = [string]$p.To
        if ($encName -eq 'UTF16LE') {
            $fromBytes = [System.Text.Encoding]::Unicode.GetBytes($fromStr)
            $toBytes   = [System.Text.Encoding]::Unicode.GetBytes($toStr)
        } elseif ($encName -eq 'UTF8') {
            $utf8 = [System.Text.UTF8Encoding]::new($false, $false)
            $fromBytes = $utf8.GetBytes($fromStr)
            $toBytes   = $utf8.GetBytes($toStr)
        } else {
            throw "Unknown encoding for ZTool.dll patch: $encName"
        }
        if ($toBytes.Length -ne $fromBytes.Length) {
            throw ("ZTool.dll patch length mismatch at offset 0x{0:X}: from={1}B to={2}B (string '{3}' -> '{4}')" -f $offset, $fromBytes.Length, $toBytes.Length, $fromStr, $toStr)
        }
        if (($offset + $fromBytes.Length) -gt $bytes.Length) {
            throw ("ZTool.dll patch offset 0x{0:X} + len {1} exceeds file size {2}" -f $offset, $fromBytes.Length, $bytes.Length)
        }
        # Verify the source bytes match
        $matches = $true
        for ($k = 0; $k -lt $fromBytes.Length; $k++) {
            if ($bytes[$offset + $k] -ne $fromBytes[$k]) { $matches = $false; break }
        }
        if (-not $matches) {
            $actualHex = [BitConverter]::ToString($bytes[$offset..($offset + $fromBytes.Length - 1)]).Replace('-','').ToLowerInvariant()
            $expHex    = [BitConverter]::ToString($fromBytes).Replace('-','').ToLowerInvariant()
            throw ("ZTool.dll byte mismatch at offset 0x{0:X}: expected {1} got {2}" -f $offset, $expHex, $actualHex)
        }
        # Apply
        for ($k = 0; $k -lt $toBytes.Length; $k++) {
            $bytes[$offset + $k] = $toBytes[$k]
        }
        $applied++
        $report.Add(("0x{0:X8} {1} '{2}' -> '{3}'" -f $offset, $encName, $fromStr, $toStr))
    }

    # Detect any RESIDUAL UTF-8 CJK in the patched file (Vista=>excluded ASCII bytes, only CJK ranges)
    $residualCjk = 0
    $i = 0
    while ($i -lt $bytes.Length - 2) {
        $b0 = $bytes[$i]
        if ($b0 -ge 0xE4 -and $b0 -le 0xE9 -and $bytes[$i+1] -ge 0x80 -and $bytes[$i+1] -le 0xBF -and $bytes[$i+2] -ge 0x80 -and $bytes[$i+2] -le 0xBF) {
            $residualCjk++
            $i += 3
        } else {
            $i++
        }
    }

    [System.IO.File]::WriteAllBytes($DllPath, $bytes)

    return @{
        AppliedPatches = $applied
        PatchDetails   = $report
        ResidualUtf8CjkSequences = $residualCjk
    }
}

# ZTool.dll's .NET #US (user-strings) heap contains 191 Chinese strings referenced by
# obfuscated IL ldstr operands. The obfuscator (NecroBit) encrypts method bodies, so
# we cannot patch ldstr operands directly. Instead, we replace strings *in place* in
# the #US heap using length-preserving UTF-16LE byte substitution (each Chinese char
# = 2 bytes UTF-16LE; each Cyrillic/ASCII char = 2 bytes UTF-16LE; replacement must
# preserve total char count). Translation table is shipped as JSON data file.
function Invoke-ZToolDllUsHeapCjkPatches([string]$DllPath, [string]$Language, [string]$TranslationsJsonPath) {
    if (-not (Test-Path -LiteralPath $DllPath -PathType Leaf)) {
        throw "ZTool.dll not found for #US heap CJK patching: $DllPath"
    }
    if (-not (Test-Path -LiteralPath $TranslationsJsonPath -PathType Leaf)) {
        throw "Translation table JSON not found: $TranslationsJsonPath"
    }
    $jsonText = [System.IO.File]::ReadAllText($TranslationsJsonPath, [System.Text.UTF8Encoding]::new($false))
    $translations = $jsonText | ConvertFrom-Json
    if ($null -eq $translations) {
        throw "Failed to parse translation table JSON: $TranslationsJsonPath"
    }
    $langField = if ($Language -eq 'English') { 'en' } else { 'ru' }

    $bytes = [System.IO.File]::ReadAllBytes($DllPath)
    $applied = 0
    $verifyFails = 0
    $report = New-Object 'System.Collections.Generic.List[string]'
    $utf16 = [System.Text.Encoding]::Unicode

    foreach ($t in $translations) {
        $offset = [int]$t.offset
        $cn = [string]$t.text
        $repl = [string]($t.$langField)
        $cnBytes = $utf16.GetBytes($cn)
        $reBytes = $utf16.GetBytes($repl)
        if ($cnBytes.Length -ne $reBytes.Length) {
            throw ("#US patch length mismatch at offset 0x{0:X}: cn={1}B repl={2}B (cn='{3}' repl='{4}')" -f $offset, $cnBytes.Length, $reBytes.Length, $cn, $repl)
        }
        if (($offset + $cnBytes.Length) -gt $bytes.Length) {
            throw ("#US patch offset 0x{0:X} + len {1} exceeds file size {2}" -f $offset, $cnBytes.Length, $bytes.Length)
        }
        # Verify source bytes match (skip if mismatch -- string may have been already patched
        # by upstream Constant.Value patches; record but do not throw).
        $ok = $true
        for ($k = 0; $k -lt $cnBytes.Length; $k++) {
            if ($bytes[$offset + $k] -ne $cnBytes[$k]) { $ok = $false; break }
        }
        if (-not $ok) {
            $verifyFails++
            $report.Add(("SKIP 0x{0:X8} '{1}' (already patched or moved)" -f $offset, $cn))
            continue
        }
        for ($k = 0; $k -lt $reBytes.Length; $k++) {
            $bytes[$offset + $k] = $reBytes[$k]
        }
        $applied++
    }

    # Residual CJK scan: walk the #US heap structurally (parse each string by length-prefix
    # and count CJK chars only within valid string bodies). Naive even-offset scanning
    # produces false positives from compressed-length prefix bytes that happen to form
    # CJK-range UTF-16LE pairs.
    $us_off = 0x546b4
    $us_size = 0x3408
    $residualCjkInStrings = 0
    $i = 1
    while ($i -lt $us_size) {
        $b0 = $bytes[$us_off + $i]
        if (($b0 -band 0x80) -eq 0) { $bl = $b0; $sz = 1 }
        elseif (($b0 -band 0xC0) -eq 0x80) { $bl = (($b0 -band 0x3F) -shl 8) -bor $bytes[$us_off + $i + 1]; $sz = 2 }
        else { $bl = (($b0 -band 0x1F) -shl 24) -bor ($bytes[$us_off + $i + 1] -shl 16) -bor ($bytes[$us_off + $i + 2] -shl 8) -bor $bytes[$us_off + $i + 3]; $sz = 4 }
        if ($bl -eq 0) { $i += $sz; continue }
        $sbc = $bl - 1
        $sds = $i + $sz
        if (($sbc % 2) -ne 0 -or $sbc -eq 0 -or ($sds + $sbc) -gt $us_size) {
            $i = $sds + $sbc + 1; continue
        }
        # Count CJK chars in this string
        for ($k = 0; $k -lt $sbc; $k += 2) {
            $code = [int]$bytes[$us_off + $sds + $k] -bor ([int]$bytes[$us_off + $sds + $k + 1] -shl 8)
            if ($code -ge 0x4E00 -and $code -le 0x9FFF) {
                $residualCjkInStrings++
            }
        }
        $i = $sds + $sbc + 1
    }

    [System.IO.File]::WriteAllBytes($DllPath, $bytes)
    return @{
        AppliedPatches = $applied
        VerifyFailures = $verifyFails
        ResidualUtf16CjkChars = $residualCjkInStrings
        PatchDetails = $report
    }
}

function Inject-LanguageField([dnlib.DotNet.ModuleDef]$Module) {
    $configType = $Module.Find('ZTool.CConfigDO', $true)
    if ($null -eq $configType) {
        throw 'Type ZTool.CConfigDO not found.'
    }
    
    foreach ($field in $configType.Fields) {
        if ([string]$field.Name -eq 'Language') {
            return 'Language field already present in CConfigDO'
        }
    }
    
    $fieldSig = [dnlib.DotNet.FieldSig]::new($Module.CorLibTypes.String)
    $field = [dnlib.DotNet.FieldDefUser]::new('Language', $fieldSig, [dnlib.DotNet.FieldAttributes]::Public)
    $configType.Fields.Add($field)
    return 'Language field injected into CConfigDO'
}

function Patch-OptionsFormLanguageSelector([dnlib.DotNet.ModuleDef]$Module, [dnlib.DotNet.ModuleDef]$LicenseModule) {
    $optionsFormType = $Module.Find('ZTool.FrmOptions', $true)
    if ($null -eq $optionsFormType) {
        throw 'Type ZTool.FrmOptions not found.'
    }
    
    $ctors = @($optionsFormType.Methods | Where-Object { $_.IsConstructor -and -not $_.IsStatic })
    if ($ctors.Count -eq 0) {
        throw 'Non-static constructor for FrmOptions not found.'
    }
    
    $langMngType = $LicenseModule.Find('ZTool.License.LanguageManager', $true)
    $addSelectorMethod = $langMngType.FindMethod('AddLanguageSelector')
    $importedMethod = $Module.Import($addSelectorMethod)
    
    $patched = 0
    foreach ($ctor in $ctors) {
        if (-not $ctor.HasBody) { continue }
        
        $alreadyInjected = $false
        foreach ($inst in $ctor.Body.Instructions) {
            $op = $inst.Operand -as [dnlib.DotNet.IMethod]
            if ($null -ne $op -and $op.Name -eq 'AddLanguageSelector') {
                $alreadyInjected = $true
                break
            }
        }
        if ($alreadyInjected) { continue }
        
        $instructions = $ctor.Body.Instructions
        $i = 0
        while ($i -lt $instructions.Count) {
            if ($instructions[$i].OpCode -eq [dnlib.DotNet.Emit.OpCodes]::Ret) {
                $instructions.Insert($i, [dnlib.DotNet.Emit.OpCodes]::Ldarg_0.ToInstruction())
                $instructions.Insert($i + 1, [dnlib.DotNet.Emit.OpCodes]::Call.ToInstruction($importedMethod))
                $i += 2
            }
            $i++
        }
        $ctor.Body.MaxStack = [Math]::Max($ctor.Body.MaxStack, 1)
        $patched++
    }
    
    return "AddLanguageSelector injected into $patched constructor(s) of FrmOptions"
}

function Patch-FormConstructorsTranslation([dnlib.DotNet.ModuleDef]$Module, [dnlib.DotNet.ModuleDef]$LicenseModule) {
    $langMngType = $LicenseModule.Find('ZTool.License.LanguageManager', $true)
    $translateMethod = $langMngType.FindMethod('TranslateForm')
    $importedMethod = $Module.Import($translateMethod)
    
    $patched = 0
    foreach ($type in $Module.GetTypes()) {
        $isForm = $false
        $current = $type.BaseType
        while ($null -ne $current) {
            if ($current.FullName -eq 'System.Windows.Forms.Form') {
                $isForm = $true
                break
            }
            try {
                $resolved = $current.Resolve()
                if ($null -eq $resolved) { break }
                $current = $resolved.BaseType
            } catch {
                break
            }
        }
        
        if (-not $isForm) { continue }
        
        foreach ($method in $type.Methods) {
            if ($method.IsConstructor -and -not $method.IsStatic -and $method.HasBody) {
                $alreadyPatched = $false
                foreach ($inst in $method.Body.Instructions) {
                    $op = $inst.Operand -as [dnlib.DotNet.IMethod]
                    if ($null -ne $op -and $op.Name -eq 'TranslateForm') {
                        $alreadyPatched = $true
                        break
                    }
                }
                if ($alreadyPatched) { continue }
                
                $instructions = $method.Body.Instructions
                $i = 0
                while ($i -lt $instructions.Count) {
                    if ($instructions[$i].OpCode -eq [dnlib.DotNet.Emit.OpCodes]::Ret) {
                        $instructions.Insert($i, [dnlib.DotNet.Emit.OpCodes]::Ldarg_0.ToInstruction())
                        $instructions.Insert($i + 1, [dnlib.DotNet.Emit.OpCodes]::Call.ToInstruction($importedMethod))
                        $i += 2
                        $patched++
                    }
                    $i++
                }
                $method.Body.MaxStack = [Math]::Max($method.Body.MaxStack, 1)
            }
        }
    }
    return "$patched form constructors patched with TranslateForm"
}

function Patch-MessageBoxCalls([dnlib.DotNet.ModuleDef]$Module, [dnlib.DotNet.ModuleDef]$LicenseModule) {
    $langMngType = $LicenseModule.Find('ZTool.License.LanguageManager', $true)
    $showMsgMethods = @()
    foreach ($m in $langMngType.Methods) {
        if ($m.Name -eq 'ShowMessageBox') {
            $showMsgMethods += $m
        }
    }
    
    $patched = 0
    foreach ($type in $Module.GetTypes()) {
        foreach ($method in $type.Methods) {
            if (-not $method.HasBody) { continue }
            $instructions = $method.Body.Instructions
            for ($i = 0; $i -lt $instructions.Count; $i++) {
                $inst = $instructions[$i]
                if ($inst.OpCode -eq [dnlib.DotNet.Emit.OpCodes]::Call -or $inst.OpCode -eq [dnlib.DotNet.Emit.OpCodes]::Callvirt) {
                    $op = $inst.Operand -as [dnlib.DotNet.IMethod]
                    if ($null -ne $op -and $op.DeclaringType.FullName -eq 'System.Windows.Forms.MessageBox' -and $op.Name -eq 'Show') {
                        $matchedMethod = $null
                        foreach ($target in $showMsgMethods) {
                            if ($target.MethodSig.Params.Count -eq $op.MethodSig.Params.Count) {
                                $match = $true
                                for ($p = 0; $p -lt $op.MethodSig.Params.Count; $p++) {
                                    if ($target.MethodSig.Params[$p].FullName -ne $op.MethodSig.Params[$p].FullName) {
                                        $match = $false
                                        break
                                    }
                                }
                                if ($match) {
                                    $matchedMethod = $target
                                    break
                                }
                            }
                        }
                        
                        if ($null -ne $matchedMethod) {
                            $imported = $Module.Import($matchedMethod)
                            $inst.OpCode = [dnlib.DotNet.Emit.OpCodes]::Call
                            $inst.Operand = $imported
                            $patched++
                        }
                    }
                }
            }
        }
    }
    return $patched
}

function Patch-ChineseLdstrTranslations([dnlib.DotNet.ModuleDef]$Module, [string]$Language = 'Russian') {
    # Load translation map dynamically
    $map = $null
    $patchScript = Join-Path $PSScriptRoot 'Patch-SWToolNativePayloadResources.ps1'
    if (Test-Path -LiteralPath $patchScript -PathType Leaf) {
        $scriptContent = Get-Content -LiteralPath $patchScript -Raw -Encoding UTF8
        $startIndex = $scriptContent.IndexOf("function Get-StringMap")
        $endIndex = $scriptContent.IndexOf("function Test-NativeRuntimeStarts")
        if ($startIndex -ge 0 -and $endIndex -gt $startIndex) {
            $functionCode = $scriptContent.Substring($startIndex, $endIndex - $startIndex)
            Invoke-Expression $functionCode
            # Hint Get-StringMap to the payload-resources companion-file dir
            # so the Update_log / regexhelp blocks are merged into the ldstr
            # map (the helper ALSO uses this map, but ldstr coverage of these
            # multi-line blocks is harmless and keeps both code paths in sync).
            $Global:SwToolPayloadResourceTextRoot = Join-Path $PSScriptRoot '..\payload-resources'
            try {
                $map = Get-StringMap $Language
            } finally {
                Remove-Variable -Scope Global -Name SwToolPayloadResourceTextRoot -ErrorAction SilentlyContinue
            }
        }
    }
    
    if ($null -eq $map) {
        throw "Failed to load translation map for Chinese strings."
    }

    # Pre-build a trimmed-key mapping to handle cases where space layout in translation map keys differs from IL strings
    $trimmedMap = [ordered]@{}
    foreach ($key in $map.Keys) {
        $trimmedKey = $key.Trim()
        if (-not $trimmedMap.Contains($trimmedKey)) {
            $trimmedMap[$trimmedKey] = $map[$key]
        }
    }

    $patched = 0
    foreach ($type in $Module.GetTypes()) {
        foreach ($method in $type.Methods) {
            if (-not $method.HasBody) { continue }
            
            $instructions = $method.Body.Instructions
            for ($i = 0; $i -lt $instructions.Count; $i++) {
                $inst = $instructions[$i]
                if ($inst.OpCode -eq [dnlib.DotNet.Emit.OpCodes]::Ldstr) {
                    $val = $inst.Operand -as [string]
                    if ($null -ne $val) {
                        $trimmedVal = $val.Trim()
                        
                        # Find translation using exact match, trimmed key, or trimmed dictionary
                        $translated = $null
                        if ($map.Contains($val)) {
                            $translated = $map[$val]
                        } elseif ($trimmedMap.Contains($val)) {
                            $translated = $trimmedMap[$val]
                        } elseif ($map.Contains($trimmedVal)) {
                            $translated = $map[$trimmedVal]
                        } elseif ($trimmedMap.Contains($trimmedVal)) {
                            $translated = $trimmedMap[$trimmedVal]
                        }
                        
                        if ($null -ne $translated) {
                            # Extract leading and trailing whitespaces of the original string
                            $leadingSpaces = ""
                            $idx = 0
                            while ($idx -lt $val.Length -and [char]::IsWhiteSpace($val[$idx])) {
                                $leadingSpaces += $val[$idx]
                                $idx++
                            }
                            $trailingSpaces = ""
                            $idx = $val.Length - 1
                            while ($idx -ge 0 -and [char]::IsWhiteSpace($val[$idx])) {
                                $trailingSpaces = $val[$idx] + $trailingSpaces
                                $idx--
                            }
                            
                            # Merge leading/trailing spaces cleanly to avoid duplicate/missing spaces
                            $result = $translated
                            if ($leadingSpaces -and -not $result.StartsWith($leadingSpaces)) {
                                $result = $leadingSpaces + $result
                            }
                            if ($trailingSpaces -and -not $result.EndsWith($trailingSpaces)) {
                                $result = $result + $trailingSpaces
                            }
                            
                            $inst.Operand = $result
                            $patched++
                        }
                    }
                }
            }
        }
    }
    return $patched
}

function Get-CscPath {
    $candidate = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return $candidate
    }

    throw "csc.exe not found: $candidate"
}

function Get-ResourcePatchHelper {
    $helperDir = Join-Path ([System.IO.Path]::GetTempPath()) 'swtool-native-resource-patcher'
    New-Item -ItemType Directory -Force -Path $helperDir | Out-Null
    $helperSource = Join-Path $helperDir 'SwToolResourcePatchHelper.cs'
    $helperExe = Join-Path $helperDir 'SwToolResourcePatchHelper.exe'

    if (Test-Path -LiteralPath $helperExe -PathType Leaf) {
        return $helperExe
    }

    @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Resources;
using System.Text;

public static class SwToolResourcePatchHelper
{
    public static int Main(string[] args)
    {
        if (args.Length != 3)
        {
            Console.Error.WriteLine("usage: <input.resources> <output.resources> <map.tsv>");
            return 2;
        }

        // The PowerShell side writes records using 0x07 as key/value separator
        // and 0x08 as record separator so multi-line keys (Update_log, regexhelp)
        // survive the round-trip. Parse the whole file as a single string.
        var map = new Dictionary<string, string>();
        string raw = File.ReadAllText(args[2], Encoding.UTF8);
        foreach (string record in raw.Split('\u0008'))
        {
            if (string.IsNullOrEmpty(record)) continue;
            int sep = record.IndexOf('\u0007');
            if (sep <= 0) continue;
            map[record.Substring(0, sep)] = record.Substring(sep + 1);
        }

        var entries = new List<DictionaryEntry>();
        int changed = 0;
        using (ResourceReader reader = new ResourceReader(args[0]))
        {
            foreach (DictionaryEntry entry in reader)
            {
                object value = entry.Value;
                string text = value as string;
                if (text != null && map.ContainsKey(text))
                {
                    value = map[text];
                    changed++;
                }

                entries.Add(new DictionaryEntry(entry.Key, value));
            }
        }

        using (ResourceWriter writer = new ResourceWriter(args[1]))
        {
            foreach (DictionaryEntry entry in entries)
            {
                writer.AddResource((string)entry.Key, entry.Value);
            }
            writer.Generate();
        }

        Console.WriteLine(changed.ToString());
        return 0;
    }
}
'@ | Set-Content -LiteralPath $helperSource -Encoding UTF8

    & (Get-CscPath) /nologo /codepage:65001 /r:System.Drawing.dll /r:System.Windows.Forms.dll /out:$helperExe $helperSource | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $helperExe -PathType Leaf)) {
        throw 'Failed to compile resource patch helper.'
    }

    return $helperExe
}

function Patch-PayloadResources([dnlib.DotNet.ModuleDef]$Module, [string]$Language) {
    $map = $null
    $patchScript = Join-Path $PSScriptRoot 'Patch-SWToolNativePayloadResources.ps1'
    if (Test-Path -LiteralPath $patchScript -PathType Leaf) {
        $scriptContent = Get-Content -LiteralPath $patchScript -Raw -Encoding UTF8
        $startIndex = $scriptContent.IndexOf("function Get-StringMap")
        $endIndex = $scriptContent.IndexOf("function Test-NativeRuntimeStarts")
        if ($startIndex -ge 0 -and $endIndex -gt $startIndex) {
            $functionCode = $scriptContent.Substring($startIndex, $endIndex - $startIndex)
            Invoke-Expression $functionCode
            # Hint Get-StringMap to the payload-resources companion-file dir.
            # When invoked via Invoke-Expression neither $PSScriptRoot nor
            # $PSCommandPath is populated, so without the explicit hint the
            # Update_log / regexhelp file pairs (6+ KB multi-line CJK blocks)
            # are silently dropped from the translation map.
            $Global:SwToolPayloadResourceTextRoot = Join-Path $PSScriptRoot '..\payload-resources'
            try {
                $map = Get-StringMap $Language
            } finally {
                Remove-Variable -Scope Global -Name SwToolPayloadResourceTextRoot -ErrorAction SilentlyContinue
            }
        }
    }
    
    if ($null -eq $map) {
        throw "Failed to load translation map for resources."
    }

    $mapPath = Join-Path ([System.IO.Path]::GetTempPath()) ("swtool-resource-map-" + [guid]::NewGuid().ToString('N') + '.tsv')
    # Use 0x07 (BEL) and 0x08 (BS) as field/record separators so multi-line
    # keys (Update_log, regexhelp) survive the round-trip. The C# helper
    # (SwToolResourcePatchHelper) reads the file with the same separators.
    $kvSep = [char]0x07
    $recSep = [char]0x08
    $sb = New-Object System.Text.StringBuilder
    foreach ($entry in $map.GetEnumerator()) {
        [void]$sb.Append([string]$entry.Key)
        [void]$sb.Append($kvSep)
        [void]$sb.Append([string]$entry.Value)
        [void]$sb.Append($recSep)
    }
    [System.IO.File]::WriteAllText($mapPath, $sb.ToString(), [System.Text.Encoding]::UTF8)

    $helper = Get-ResourcePatchHelper
    
    $resourcesToPatch = @(
        'ZTool.Frmmain.resources',
        'ZTool.FrmOptions.resources',
        'ZTool.Resources.resources'
    )
    
    $patchedCount = 0
    
    try {
        foreach ($resourceName in $resourcesToPatch) {
            $idx = -1
            for ($i = 0; $i -lt $Module.Resources.Count; $i++) {
                if ($Module.Resources[$i].Name -eq $resourceName) {
                    $idx = $i
                    break
                }
            }
            if ($idx -lt 0) {
                continue
            }
            
            $oldResource = $Module.Resources[$idx] -as [dnlib.DotNet.EmbeddedResource]
            $reader = $oldResource.CreateReader()
            $oldResourceBytes = $reader.ReadBytes([int]$reader.Length)
            
            $oldResourcePath = Join-Path ([System.IO.Path]::GetTempPath()) ("swtool-old-" + [guid]::NewGuid().ToString('N') + '.resources')
            $newResourcePath = Join-Path ([System.IO.Path]::GetTempPath()) ("swtool-new-" + [guid]::NewGuid().ToString('N') + '.resources')
            
            [System.IO.File]::WriteAllBytes($oldResourcePath, $oldResourceBytes)
            try {
                $changedText = (& $helper $oldResourcePath $newResourcePath $mapPath | ForEach-Object { [string]$_ }) -join "`n"
                if ($LASTEXITCODE -ne 0) {
                    throw "Resource helper failed for $resourceName"
                }
                
                if (Test-Path -LiteralPath $newResourcePath -PathType Leaf) {
                    $newResourceBytes = [System.IO.File]::ReadAllBytes($newResourcePath)
                    
                    $newResource = [dnlib.DotNet.EmbeddedResource]::new(
                        [dnlib.DotNet.UTF8String]$resourceName,
                        $newResourceBytes,
                        $oldResource.Attributes
                    )
                    $Module.Resources[$idx] = $newResource
                    $patchedCount++
                }
            } finally {
                Remove-Item -LiteralPath $oldResourcePath, $newResourcePath -Force -ErrorAction SilentlyContinue
            }
        }
    } finally {
        Remove-Item -LiteralPath $mapPath -Force -ErrorAction SilentlyContinue
    }
    
    return $patchedCount
}

function Patch-CyrillicLdstr([dnlib.DotNet.ModuleDef]$Module, [dnlib.DotNet.IMethod]$TranslateMethod) {
    $patched = 0
    foreach ($type in $Module.GetTypes()) {
        foreach ($method in $type.Methods) {
            if (-not $method.HasBody) { continue }
            
            $isTarget = $false
            if ($Module.Name -eq 'ZTool.dll') {
                if ($type.FullName -eq 'ZTool.SwAddin' -and $method.Name -eq 'AddCommandMgr') {
                    $isTarget = $true
                }
            } else {
                if ($type.FullName.StartsWith('ZTool.Frm', [System.StringComparison]::Ordinal) -or 
                    $type.FullName.StartsWith('ZTool.frm_', [System.StringComparison]::Ordinal)) {
                    $isTarget = $true
                }
            }
            
            if (-not $isTarget) { continue }
            
            $instructions = $method.Body.Instructions
            $i = 0
            while ($i -lt $instructions.Count) {
                $inst = $instructions[$i]
                if ($inst.OpCode -eq [dnlib.DotNet.Emit.OpCodes]::Ldstr) {
                    $val = $inst.Operand -as [string]
                    if ($null -ne $val -and $val -match '[\u0400-\u04FF]') {
                        $callInst = [dnlib.DotNet.Emit.OpCodes]::Call.ToInstruction($TranslateMethod)
                        $instructions.Insert($i + 1, $callInst)
                        $i++
                        $patched++
                    }
                }
                $i++
            }
        }
    }
    return $patched
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
$originalAddInPublicKeys = Get-OriginalAssemblyRefPublicKeys (Join-Path (Split-Path -Parent $repoRoot) 'reference\ZTool-original\ZTool.dll')
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

    $licenseModule = [dnlib.DotNet.ModuleDefMD]::Load($licenseDllPath)
    try {
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
            $codeStaticConstructorPatched = if ($SkipLicenseGatePatch) {
                'ZTool.code::.cctor license gate reset skipped by request'
            } else {
                Reset-CodeStaticConstructorLicenseGate $payloadModule
            }
            Set-MethodReturnString $payloadModule 'ZTool.code' 'Getpkt' $ztoolProtocolToken
            $programMainLicenseGatePatched = if ($SkipLicenseGatePatch) {
                'ZTool.Program::Main LicenseGate patch skipped by request'
            } else {
                Patch-ProgramMainLicenseGate $payloadModule $licenseDllPath
            }
            $legacyChecklicPatched = @(Patch-LegacyChecklicTimer $payloadModule)
            $frmmainSolidWorksLaunchAutoConnectPatched = @('ZTool.Frmmain SolidWorks launch auto-connect intentionally not patched; original active-document workflow preserved')
            $registrationTransferPatched = if ($SkipLicenseGatePatch) {
                'ZTool.FrmRg::Button2_Click license transfer patch skipped by request'
            } else {
                Patch-RegistrationTransferButton $payloadModule
            }
            
            # Keep the original ZTool runtime flow intact. Only inject the
            # language option entry point; broad form rewrites are handled by
            # runtime branding/translation to avoid destabilizing commands.
            if ($SkipLanguageSelectorPatch) {
                $langFieldInjected = 'Language field injection skipped by request'
                $langSelectorInjected = 'FrmOptions language selector injection skipped by request'
            } else {
                $langFieldInjected = Inject-LanguageField $payloadModule
                $langSelectorInjected = Patch-OptionsFormLanguageSelector $payloadModule $licenseModule
            }
            $langMngType = $licenseModule.Find('ZTool.License.LanguageManager', $true)
            $translateMethod = $langMngType.FindMethod('Translate')
            $importedTranslateMethod = $payloadModule.Import($translateMethod)

            $formCtorsPatched = Patch-FormConstructorsTranslation $payloadModule $licenseModule
            $messageBoxesPatched = Patch-MessageBoxCalls $payloadModule $licenseModule
            $payloadChineseTranslated = Patch-ChineseLdstrTranslations $payloadModule $Language
            $payloadResourcesPatched = Patch-PayloadResources $payloadModule $Language
            $payloadCyrillicPatched = Patch-CyrillicLdstr $payloadModule $importedTranslateMethod

            $hasShellPatched = Patch-HasShell $payloadModule
            $payloadAssemblyRefsRepaired = @(Repair-TokenSizedPublicKeyAssemblyRefs $payloadModule $originalAddInPublicKeys)
            Write-StrongNamedModule $payloadModule $payloadPatched $strongNameKey
        } finally {
            $payloadModule.Dispose()
        }

        $patchedPayloadBytes = [System.IO.File]::ReadAllBytes($payloadPatched)
        $encryptedPatchedPayload = ConvertTo-ZToolPayloadResource $patchedPayloadBytes

        $finalModule = [dnlib.DotNet.ModuleDefMD]::Load($payloadPatched)
        try {
            $resource = [dnlib.DotNet.EmbeddedResource]::new(
                [dnlib.DotNet.UTF8String]$resourceName,
                $encryptedPatchedPayload,
                [dnlib.DotNet.ManifestResourceAttributes]::Public
            )
            $finalModule.Resources.Add($resource)
            Write-StrongNamedModule $finalModule $exePatched $strongNameKey
            $outerAssemblyRefsRepaired = @('ZTool.exe is direct payload, outer assembly refs repair skipped')
        } finally {
            $finalModule.Dispose()
        }

        Copy-Item -LiteralPath $exePatched -Destination $exePath -Force

        # ZTool.exe still carries CJK in two regions even after dnlib rewrite:
        #  1) AssemblyDescription/AssemblyTitle custom-attribute string blobs
        #     (UTF-8 length-prefixed strings inside the #Blob heap, preserved by PreserveAll)
        #  2) UAC application manifest XML in .rsrc Win32 resource (Chinese comments)
        # Both are patched in-place via length-preserving UTF-8 byte search-and-replace.
        $outerExeBinaryPatchResult = Invoke-ZToolExeBinaryStringPatches -ExePath $exePath -Language $Language
        $outerExeBinaryPatchCount = $outerExeBinaryPatchResult.TotalReplacements
        $outerExeBinaryPatchResidual = $outerExeBinaryPatchResult.ResidualUtf8CjkSequences

        $addinPath = Join-Path $packageRootFull 'ZTool.dll'
        if (-not (Test-Path -LiteralPath $addinPath -PathType Leaf)) {
            throw "ZTool.dll not found: $addinPath"
        }

        if ([string]::IsNullOrWhiteSpace($OriginalAddInPath)) {
            $repoRoot = Resolve-FullPath (Join-Path $PSScriptRoot '..\..\..')
            $OriginalAddInPath = Join-Path $repoRoot 'reference\ZTool-original\ZTool.dll'
        }
        $originalAddInFull = Resolve-FullPath $OriginalAddInPath
        if (-not (Test-Path -LiteralPath $originalAddInFull -PathType Leaf)) {
            throw "Original SolidWorks add-in not found: $originalAddInFull"
        }

        Copy-Item -LiteralPath $originalAddInFull -Destination $addinPath -Force

        # ZTool.dll is .NET Reactor-obfuscated and cannot be round-trip rewritten by dnlib
        # (malformed IL with null-target short branches). We apply length-preserving
        # in-place byte patches to remove residual CJK from Constant.Value blobs (template
        # tokens like $图号$, $零件名称$, $版本$, <磁盘文件名>, <配置名称>) and from
        # CustomAttribute blobs (AssemblyDescription, AssemblyTitle). Strong-name
        # signature becomes invalid after byte patching; the installer registers a
        # skip-verification entry (sn -Vr ZTool,*) to allow the modified DLL to load.
        # #US heap CJK patches FIRST: 191 user-strings referenced by obfuscated IL.
        # The translation table is shipped as a JSON file in payload-resources/. Each
        # translation is length-equal (UTF-16LE char count) so the heap structure is
        # preserved and ldstr tokens remain valid. Must run BEFORE Get-ZToolDllCjkPatches
        # so that the in-heap occurrences of $图号$ etc. get translated by the JSON table,
        # leaving Get-ZToolDllCjkPatches to handle only the #Blob duplicates.
        $usTranslationsPath = Join-Path -Path (Join-Path $PSScriptRoot '..\payload-resources') -ChildPath 'ztool-dll-us-cjk-patches.json'
        $usPatchResult = Invoke-ZToolDllUsHeapCjkPatches -DllPath $addinPath -Language $Language -TranslationsJsonPath $usTranslationsPath
        $usPatchCount = $usPatchResult.AppliedPatches
        $usPatchVerifyFails = $usPatchResult.VerifyFailures
        $usPatchResidualCjk = $usPatchResult.ResidualUtf16CjkChars

        $addinBinaryPatchResult = Invoke-ZToolDllBinaryStringPatches -DllPath $addinPath -Language $Language
        $addinBinaryPatchCount = $addinBinaryPatchResult.AppliedPatches
        $addinBinaryPatchResidualCjk = $addinBinaryPatchResult.ResidualUtf8CjkSequences

        $solidWorksAddInAudited = @(
            "ZTool.dll #US heap CJK patches applied=$usPatchCount verify-fails=$usPatchVerifyFails residual-utf16-cjk-chars=$usPatchResidualCjk",
            "ZTool.dll #Blob/attribute CJK byte patches applied=$addinBinaryPatchCount residual-utf8-cjk-runs=$addinBinaryPatchResidualCjk",
            'ZTool.dll IL preserved byte-for-byte (obfuscated SolidWorks IPC/add-in flow is not rewritten)'
        )
        $solidWorksImageResourcesPatched = @('original linked SolidWorks toolbar resources preserved')
        $addinFormCtorsPatched = 'addin form constructor localization skipped; original IPC flow preserved'
        $addinMessageBoxesPatched = 'addin MessageBox localization skipped; original IPC flow preserved'
        $addinCyrillicPatched = 'addin Cyrillic ldstr localization skipped; original IPC flow preserved'
        $addinAssemblyRefsRepaired = @('addin AssemblyRefs intentionally preserved from reference original')

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
            "$registrationTransferPatched uses ZTool.License.LicenseGate::DeactivateWithPassword",
            $langFieldInjected,
            $langSelectorInjected,
            $formCtorsPatched,
            "$payloadChineseTranslated payload Chinese ldstr strings patched",
            "$payloadResourcesPatched payload resources patched using dnlib",
            "$messageBoxesPatched payload MessageBox calls patched",
            "$payloadCyrillicPatched payload Cyrillic strings patched",
            "$addinFormCtorsPatched addin form constructors patched",
            "$addinMessageBoxesPatched addin MessageBox calls patched",
            "$addinCyrillicPatched addin Cyrillic strings patched",
            "ZTool.exe CJK byte patches: total-replacements=$outerExeBinaryPatchCount residual-utf8-cjk-runs=$outerExeBinaryPatchResidual"
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
        $licenseModule.Dispose()
    }
} finally {
    Remove-Item -LiteralPath $payloadTemp -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $payloadPatched -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $exePatched -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $addinPatched -Force -ErrorAction SilentlyContinue
}
