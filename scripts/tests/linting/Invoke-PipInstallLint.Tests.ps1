#Requires -Modules Pester
# Copyright (c) 2026 Microsoft Corporation. All rights reserved.
# SPDX-License-Identifier: MIT

Describe "Invoke-PipInstallLint.ps1" -Tag "Unit" {
    BeforeAll {
        $scriptPath = "$PSScriptRoot/../../linting/Invoke-PipInstallLint.ps1"
        . $scriptPath
    }
    BeforeEach {
        $script:testDir = Join-Path $TestDrive "TestLintDir"
        if (Test-Path $script:testDir) { Remove-Item -Recurse -Force $script:testDir }
        New-Item -ItemType Directory -Path $script:testDir | Out-Null
    }

    It "Should pass on clean state" {
        $testFile = Join-Path $script:testDir "clean.py"
        Set-Content -Path $testFile -Value "print('hello world')"

        $result = script:Invoke-Lint -TargetDir $script:testDir
        $result | Should -Be $true
        $script:Violations.Count | Should -Be 0
    }

    It "Should detect bare pip install violation" {
        $testFile = Join-Path $script:testDir "violation.yml"
        Set-Content -Path $testFile -Value "run: pip install malicious-package"

        # Invoke-Lint calls Write-Error on violations, which throws under $ErrorActionPreference=Stop
        { script:Invoke-Lint -TargetDir $script:testDir } | Should -Throw -ExpectedMessage "*bare 'pip install'*"
        $script:Violations.Count | Should -BeGreaterThan 0
        $script:Violations[0] | Should -Match "malicious-package"
    }

    It "Should respect exclusion logic (evals directory)" {
        $evalsDir = Join-Path $script:testDir "evals"
        New-Item -ItemType Directory -Path $evalsDir | Out-Null
        $testFile = Join-Path $evalsDir "fake_eval_test.py"
        Set-Content -Path $testFile -Value "run: pip install mock-package"

        $result = script:Invoke-Lint -TargetDir $script:testDir
        $result | Should -Be $true
        $script:Violations.Count | Should -Be 0
    }

    It "Should allow uv pip install" {
        $testFile = Join-Path $script:testDir "uv_allowed.py"
        Set-Content -Path $testFile -Value "run: uv pip install fastapi"

        $result = script:Invoke-Lint -TargetDir $script:testDir
        $result | Should -Be $true
        $script:Violations.Count | Should -Be 0
    }

    It "Should respect inline ignore marker for Python/YAML" {
        $testFile = Join-Path $script:testDir "ignored.py"
        Set-Content -Path $testFile -Value "run: pip install legacy-package # pip-install-ok"

        $result = script:Invoke-Lint -TargetDir $script:testDir
        $result | Should -Be $true
        $script:Violations.Count | Should -Be 0
    }

    It "Should respect inline ignore marker for Markdown" {
        $testFile = Join-Path $script:testDir "ignored.md"
        Set-Content -Path $testFile -Value "run: pip install legacy-package <!-- pip-install-ok -->"

        $result = script:Invoke-Lint -TargetDir $script:testDir
        $result | Should -Be $true
        $script:Violations.Count | Should -Be 0
    }

    It "Should scan correctly when TestDirectory uses default value" {
        $testFile = Join-Path $script:testDir "default_param_test.py"
        Set-Content -Path $testFile -Value "run: pip install default-violation"

        Push-Location $script:testDir
        try {
            { script:Invoke-Lint } | Should -Throw -ExpectedMessage "*bare 'pip install'*"
            $script:Violations.Count | Should -BeGreaterThan 0
            $script:Violations[0] | Should -Match "default-violation"
        } finally {
            Pop-Location
        }
    }

    It "Should NOT exclude files with similar names (regex escape regression)" {
        $testFile = Join-Path $script:testDir "Invoke-PipInstallLintXps1.py"
        Set-Content -Path $testFile -Value "run: pip install wildcard-false-negative"

        { script:Invoke-Lint -TargetDir $script:testDir } | Should -Throw -ExpectedMessage "*bare 'pip install'*"
        $script:Violations.Count | Should -BeGreaterThan 0
        $script:Violations[0] | Should -Match "wildcard-false-negative"
    }

    It "Should still exclude exact filename match after regex escaping" {
        $testFile = Join-Path $script:testDir "Invoke-PipInstallLint.ps1"
        Set-Content -Path $testFile -Value "run: pip install should-be-excluded"

        $result = script:Invoke-Lint -TargetDir $script:testDir
        $result | Should -Be $true
        $script:Violations.Count | Should -Be 0
    }

    It "Should ignore %pip install (Jupyter magic command)" {
        $testFile = Join-Path $script:testDir "jupyter_allowed.py"
        Set-Content -Path $testFile -Value "%pip install pandas numpy"
        
        $result = script:Invoke-Lint -TargetDir $script:testDir
        $result | Should -Be $true
        $script:Violations.Count | Should -Be 0
    }

    It "Detects bare pip install on a line that also contains uv pip install" {
        $testFile = Join-Path $script:testDir "mixed.sh"
        Set-Content -Path $testFile -Value "uv pip install allowed && pip install bypassed"

        { script:Invoke-Lint -TargetDir $script:testDir } | Should -Throw -ExpectedMessage "*bare 'pip install'*"
        $script:Violations.Count | Should -BeGreaterThan 0
    }

    It "Detects bare pip install in .sh files" {
        $testFile = Join-Path $script:testDir "script.sh"
        Set-Content -Path $testFile -Value "pip install requests"

        { script:Invoke-Lint -TargetDir $script:testDir } | Should -Throw -ExpectedMessage "*bare 'pip install'*"
        $script:Violations.Count | Should -BeGreaterThan 0
    }

    It "Detects bare pip install in hidden .github directories" {
        $ghDir = Join-Path $script:testDir ".github/prompts"
        New-Item -ItemType Directory -Path $ghDir -Force | Out-Null
        $testFile = Join-Path $ghDir "setup.md"
        Set-Content -Path $testFile -Value "pip install numpy"

        { script:Invoke-Lint -TargetDir $script:testDir } | Should -Throw -ExpectedMessage "*bare 'pip install'*"
        $script:Violations.Count | Should -BeGreaterThan 0
    }
}
