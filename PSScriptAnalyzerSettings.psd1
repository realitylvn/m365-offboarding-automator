@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # New-StepResult / Get-RunSummary are pure object factories, and the Graph
        # cmdlet wrappers in the runbook are thin pass-throughs to the SDK - none of
        # them are cmdlets that need a -WhatIf/-Confirm surface. The real safety
        # model here is the checkpointed run + partial-completion design.
        'PSUseShouldProcessForStateChangingFunctions',

        # Revoke-TargetSessions / Remove-TargetLicenses / Remove-TargetGroupMemberships
        # act on whole collections (all sessions, all SKUs, all manual groups) in one
        # call - the plural is the accurate name, and these are internal runbook
        # helpers, not exported cmdlets. The step names in the JSON summary
        # ('revoke-sessions', 'remove-licenses', 'remove-group-memberships') match.
        'PSUseSingularNouns'
    )
}
