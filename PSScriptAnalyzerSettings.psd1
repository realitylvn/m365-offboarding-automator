@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # New-StepResult / Get-RunSummary are pure object factories, and the Graph
        # cmdlet wrappers in the runbook are thin pass-throughs to the SDK - none of
        # them are cmdlets that need a -WhatIf/-Confirm surface. The real safety
        # model here is the checkpointed run + partial-completion design.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
