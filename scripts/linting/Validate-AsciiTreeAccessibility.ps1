# Copyright (c) 2026 Microsoft Corporation. All rights reserved.
# SPDX-License-Identifier: MIT

# Validate-AsciiTreeAccessibility.ps1
#
# Purpose: Validates that ASCII directory trees in Markdown files are properly
#          hidden from screen readers and have a semantic equivalent nearby.
# Author: HVE Core Team
#
# This script validates:
# - Markdown fenced code blocks containing ASCII trees are flagged as failures 
#   (they cannot be made accessible; authors must use raw HTML <pre>).
# - Any <pre> block containing ASCII tree characters (├──, └──) MUST have aria-hidden="true".
# - A semantic nested Markdown list must exist within a nearby window (default: 15 lines) 
#   before or after the <pre> block.
# - The semantic list must contain a meaningful overlap of names (folders/files) 
#   extracted from the tree to prevent false positives from unrelated lists.

#Requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$Paths = @('docs'),

    [Parameter(Mandatory = $false)]
    [string[]]$ExcludePaths = @(
        'docs\agents\backlog\discovery.md',
        'docs\agents\backlog\execution.md',
        'docs\agents\backlog\sprint-planning.md',
        'docs\agents\backlog\task-planning.md',
        'docs\agents\backlog\triage.md',
        'docs\agents\code-review\language-skills.md',
        'docs\architecture\ai-artifacts.md',
        'docs\architecture\testing.md',
        'docs\contributing\custom-agents.md',
        'docs\contributing\instructions.md',
        'docs\contributing\prompts.md',
        'docs\contributing\ROADMAP.md',
        'docs\contributing\skills.md',
        'docs\customization\custom-agents.md',
        'docs\customization\instructions.md',
        'docs\getting-started\tts-voiceover.md',
        'docs\getting-started\methods\codespaces.md',
        'docs\getting-started\methods\comparison.md',
        'docs\getting-started\methods\extension.md',
        'docs\getting-started\methods\git-ignored.md',
        'docs\getting-started\methods\mounted.md',
        'docs\getting-started\methods\multi-root.md',
        'docs\getting-started\methods\peer-clone.md',
        'docs\getting-started\methods\submodule.md',
        'docs\planning\prds\docusaurus-accessibility-conformance-prd.md',
        'docs\rpi\using-together.md',
        'docs\security\security-model.md',
        'docs\templates\skill-security-model-template.md'
    ),

    [Parameter(Mandatory = $false)]
    [int]$NearbyWindowLines = 15,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "logs/ascii-tree-a11y-results.json"
)

$ErrorActionPreference = 'Stop'

#region Type Definitions

class AsciiTreeValidationIssue {
    [string]$FilePath
    [int]$LineNumber
    [string]$Reason
    [string]$Snippet

    AsciiTreeValidationIssue([string]$filePath, [int]$lineNumber, [string]$reason, [string]$snippet) {
        $this.FilePath = $filePath
        $this.LineNumber = $lineNumber
        $this.Reason = $reason
        $this.Snippet = $snippet
    }
}

class AsciiTreeValidationSummary {
    [int]$FilesScanned = 0
    [int]$TreesFound = 0
    [int]$Failures = 0
    [AsciiTreeValidationIssue[]]$Issues = @()

    [int] GetExitCode() {
        if ($this.Failures -gt 0) { return 1 }
        return 0
    }
}

#endregion Type Definitions

#region Helper Functions

function Get-LineNumberOfIndex {
    param([string]$Content, [int]$Index)
    return ($Content.Substring(0, $Index) -split "`n").Count
}

function Get-Snippet {
    param([string]$BlockContent, [int]$MaxLines = 4)
    $lines = ($BlockContent -split "`n") | Where-Object { $_.Trim() -ne "" } | Select-Object -First $MaxLines
    return ($lines | ForEach-Object { "      | $_" }) -join "`n"
}

function Get-TreeNames {
    param([string]$BlockContent)
    $names = @()
    $lines = $BlockContent -split "`n"
    foreach ($line in $lines) {
        $clean = ($line -replace '^[├└│\s─]+', '').Trim()
        if ($clean -match '^[a-zA-Z0-9_.\-/]+$' -and $clean.Length -gt 0) {
            $names += $clean
        }
    }
    return $names | Select-Object -Unique
}

function Test-AsciiTreeAccessibility {
    [CmdletBinding()]
    [OutputType([AsciiTreeValidationSummary])]
    param(
        [string[]]$Paths,
        [string[]]$ExcludePaths,
        [int]$NearbyWindowLines
    )

    $summary = [AsciiTreeValidationSummary]::new()
    $repoRoot = (Get-Location).Path

    # Patterns
    $PreBlockPattern = '(?s)<pre\b([^>]*)>(.*?)</pre>'
    $FencedBlockPattern = '(?s)```(?:text|markdown|bash|shell|yaml|json|powershell)?\s*(.*?)```'
    $TreeCharPattern = '(├──|└──)'
    $NestedListPattern = '(?m)^[ \t]{2,}(?:[-*]|\d+\.)[ \t]+'

    foreach ($path in $Paths) {
        if (-not (Test-Path $path)) { continue }

        $files = Get-ChildItem -Path $path -Filter "*.md" -Recurse -File -ErrorAction SilentlyContinue

        foreach ($file in $files) {
            if ($file.FullName -match "node_modules") { continue }

            $relativePath = $file.FullName.Substring($repoRoot.Length).TrimStart('\', '/').Replace('/', '\')

            $isExcluded = $false
            foreach ($exclude in $ExcludePaths) {
                if ($relativePath -like $exclude) {
                    $isExcluded = $true
                    break
                }
            }
            if ($isExcluded) { continue }

            $summary.FilesScanned++
            $content = [System.IO.File]::ReadAllText($file.FullName)

            $fencedMatches = [regex]::Matches($content, $FencedBlockPattern)
            foreach ($match in $fencedMatches) {
                $blockContent = $match.Groups[1].Value
                if ($blockContent -match $TreeCharPattern) {
                    $summary.Failures++
                    $summary.Issues += [AsciiTreeValidationIssue]::new(
                        $relativePath,
                        (Get-LineNumberOfIndex -Content $content -Index $match.Index),
                        "Markdown fenced code block contains an ASCII directory tree. Fenced blocks cannot be made accessible. Use <pre aria-hidden=`"true`"> and provide a semantic nested list instead.",
                        (Get-Snippet -BlockContent $blockContent)
                    )
                }
            }

            $preMatches = [regex]::Matches($content, $PreBlockPattern)
            foreach ($match in $preMatches) {
                $attributes   = $match.Groups[1].Value
                $blockContent = $match.Groups[2].Value

                if ($blockContent -notmatch $TreeCharPattern) { continue }

                $summary.TreesFound++
                $lineNumber = Get-LineNumberOfIndex -Content $content -Index $match.Index
                $snippet    = Get-Snippet -BlockContent $blockContent

                if ($attributes -notmatch 'aria-hidden\s*=\s*["'']true["'']') {
                    $summary.Failures++
                    $summary.Issues += [AsciiTreeValidationIssue]::new(
                        $relativePath,
                        $lineNumber,
                        "ASCII tree <pre> block is missing aria-hidden=`"true`".",
                        $snippet
                    )
                    continue 
                }

                $blockStartIndex = $match.Index
                $blockEndIndex   = $match.Index + $match.Length

                $beforeChars = $content.Substring(0, $blockStartIndex)
                $beforeLines = ($beforeChars -split "`n")
                $beforeWindow = ($beforeLines | Select-Object -Last $NearbyWindowLines) -join "`n"

                $afterChars = $content.Substring($blockEndIndex)
                $afterLines = ($afterChars -split "`n")
                $afterWindow = ($afterLines | Select-Object -First $NearbyWindowLines) -join "`n"

                $treeNames = Get-TreeNames -BlockContent $blockContent
                $requiredMatches = if ($treeNames.Count -le 2) { 1 } else { [Math]::Floor($treeNames.Count / 2) }

                $isValidSemantic = $false

                # Check before window
                if ($beforeWindow -match $NestedListPattern) {
                    $matchCount = 0
                    foreach ($name in $treeNames) {
                        if ($beforeWindow -match [regex]::Escape($name)) { $matchCount++ }
                    }
                    if ($matchCount -ge $requiredMatches) { $isValidSemantic = $true }
                }

                # Check after window if not already valid
                if (-not $isValidSemantic -and ($afterWindow -match $NestedListPattern)) {
                    $matchCount = 0
                    foreach ($name in $treeNames) {
                        if ($afterWindow -match [regex]::Escape($name)) { $matchCount++ }
                    }
                    if ($matchCount -ge $requiredMatches) { $isValidSemantic = $true }
                }

                if (-not $isValidSemantic) {
                    $summary.Failures++
                    $summary.Issues += [AsciiTreeValidationIssue]::new(
                        $relativePath,
                        $lineNumber,
                        "ASCII tree has aria-hidden=`"true`" but no related semantic nested list was found within $NearbyWindowLines lines before or after. The nearby list must contain file/folder names from the tree to be considered a valid equivalent.",
                        $snippet
                    )
                }
            }
        }
    }

    return $summary
}

function Write-ValidationConsoleOutput {
    param([AsciiTreeValidationSummary]$Summary)

    Write-Host ""
    Write-Host "────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "  Files scanned : $($Summary.FilesScanned)"
    Write-Host "  Trees found   : $($Summary.TreesFound)"
    Write-Host "  Failures      : $($Summary.Failures)" -ForegroundColor $(if ($Summary.Failures -gt 0) { "Red" } else { "Green" })
    Write-Host "────────────────────────────────────────────────────────────" -ForegroundColor DarkGray

    if ($Summary.Failures -gt 0) {
        Write-Host ""
        foreach ($issue in $Summary.Issues) {
            Write-Host "❌ FAIL: $($issue.FilePath) (line $($issue.LineNumber))" -ForegroundColor Red
            Write-Host "   Reason: $($issue.Reason)" -ForegroundColor Red
            Write-Host "   Snippet:" -ForegroundColor Yellow
            Write-Host $issue.Snippet
            Write-Host "   Expected: <pre aria-hidden=`"true`"> ... </pre> paired with a nearby Markdown nested list containing the same file/folder names." -ForegroundColor Cyan
            Write-Host ""
        }
    }
}

function Export-ValidationResults {
    param(
        [AsciiTreeValidationSummary]$Summary,
        [string]$OutputPath
    )
    
    $logsDir = Split-Path -Parent $OutputPath
    if (-not (Test-Path $logsDir)) {
        New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    }

    $Summary.Issues | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputPath -Encoding UTF8
}

#endregion Helper Functions

#region Main Execution
if ($MyInvocation.InvocationName -ne '.') {
    try {
        Write-Host "🔍 Validating ASCII directory tree accessibility across markdown files..." -ForegroundColor Cyan
        
        $summary = Test-AsciiTreeAccessibility -Paths $Paths -ExcludePaths $ExcludePaths -NearbyWindowLines $NearbyWindowLines
        
        Write-ValidationConsoleOutput -Summary $summary
        Export-ValidationResults -Summary $summary -OutputPath $OutputPath

        $exitCode = $summary.GetExitCode()
        
        if ($exitCode -ne 0) {
            Write-Host "🚨 Automated accessibility check failed." -ForegroundColor Red
            Write-Host "   Each ASCII directory tree must be wrapped in <pre aria-hidden=`"true`">" -ForegroundColor Yellow
            Write-Host "   AND paired with a semantic nested Markdown list nearby that shares file/folder names." -ForegroundColor Yellow
            exit 1
        }
        else {
            Write-Host "✅ Accessibility check passed: all ASCII trees are properly remediated." -ForegroundColor Green
            Write-Host "   (Legacy exclusions still apply — see `$ExcludePaths in script parameters.)" -ForegroundColor DarkGray
            exit 0
        }
    }
    catch {
        Write-Error -ErrorAction Continue "Validate-AsciiTreeAccessibility failed: $($_.Exception.Message)"
        exit 1
    }
}
#endregion Main Execution

