BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Msec.psd1') -Force
}

Describe 'Measure-MsecDefenderTriageAgreement' {

    BeforeAll {
        # Deliberately imbalanced the way a real triage set is: mostly false positives, a few
        # true ones. That imbalance is what makes a single accuracy figure useless.
        $script:Alerts = @(
            [pscustomobject]@{ Id = '1'; Title = 'A'; Classification = 'falsePositive' }
            [pscustomobject]@{ Id = '2'; Title = 'B'; Classification = 'falsePositive' }
            [pscustomobject]@{ Id = '3'; Title = 'C'; Classification = 'falsePositive' }
            [pscustomobject]@{ Id = '4'; Title = 'D'; Classification = 'falsePositive' }
            [pscustomobject]@{ Id = '5'; Title = 'E'; Classification = 'falsePositive' }
            [pscustomobject]@{ Id = '6'; Title = 'F'; Classification = 'falsePositive' }
            [pscustomobject]@{ Id = '7'; Title = 'G'; Classification = 'falsePositive' }
            [pscustomobject]@{ Id = '8'; Title = 'H'; Classification = 'falsePositive' }
            [pscustomobject]@{ Id = '9'; Title = 'I'; Classification = 'truePositive' }
            [pscustomobject]@{ Id = '10'; Title = 'J'; Classification = 'unknown' }
        )
    }

    It 'does not let an all-falsePositive proposal look good' {
        # THE POINT OF THE COMMAND. Answering 'falsePositive' every time agrees with 8 of 9
        # labelled alerts - 89% - while catching none of the real detections. The headline
        # number flatters it; TruePositiveRecall does not.
        $v = @{}
        1..9 | ForEach-Object { $v["$_"] = 'falsePositive' }
        $r = Measure-MsecDefenderTriageAgreement -Alert $script:Alerts -Verdict $v

        $r.Agreed             | Should -Be 8
        $r.Scored             | Should -Be 9
        $r.TruePositiveRecall | Should -Be 0
    }

    It 'reports TruePositiveRecall as the proportion of real detections caught' {
        $v = @{ '1' = 'falsePositive'; '9' = 'truePositive' }
        $r = Measure-MsecDefenderTriageAgreement -Alert $script:Alerts -Verdict $v
        $r.TruePositiveRecall | Should -Be 1
        ($r.PerClass | Where-Object Class -eq 'truePositive').Actual | Should -Be 1
    }

    It 'excludes unlabelled alerts from scoring rather than counting them as disagreements' {
        # Classification 'unknown' means nobody judged it. Scoring it as a miss would punish a
        # proposal for disagreeing with a verdict that was never given.
        $v = @{}
        1..10 | ForEach-Object { $v["$_"] = 'falsePositive' }
        $r = Measure-MsecDefenderTriageAgreement -Alert $script:Alerts -Verdict $v
        $r.Scored     | Should -Be 9
        $r.Unlabelled | Should -Be 1
        $r.Detail.Id  | Should -Not -Contain '10'
    }

    It 'counts labelled alerts the proposal declined to answer' {
        # A proposal that answers two alerts out of nine and gets both right is not 100%
        # accurate, and coverage is the only thing that shows it.
        $r = Measure-MsecDefenderTriageAgreement -Alert $script:Alerts `
            -Verdict @{ '1' = 'falsePositive'; '9' = 'truePositive' }
        $r.Scored            | Should -Be 2
        $r.LabelledNoVerdict | Should -Be 7
    }

    It 'counts verdicts that match no alert in the set' {
        $r = Measure-MsecDefenderTriageAgreement -Alert $script:Alerts `
            -Verdict @{ '1' = 'falsePositive'; 'stale-id' = 'truePositive' }
        $r.OrphanVerdicts | Should -Be 1
    }

    It 'reports the shape of each disagreement, commonest first' {
        # Where a proposal is wrong is more actionable than how often.
        $v = @{ '1' = 'truePositive'; '2' = 'truePositive'; '9' = 'falsePositive' }
        $r = Measure-MsecDefenderTriageAgreement -Alert $script:Alerts -Verdict $v
        $r.Confusion[0].Shape | Should -Be 'falsePositive -> truePositive'
        $r.Confusion[0].Count | Should -Be 2
        ($r.Confusion | Where-Object Shape -eq 'truePositive -> falsePositive').Count | Should -Be 1
    }

    It 'returns null TruePositiveRecall when the set contains no true positives' {
        # Not a pass - no evidence either way, and it must not read as 1.
        $fpOnly = @($script:Alerts | Where-Object Classification -eq 'falsePositive')
        $v = @{}; $fpOnly | ForEach-Object { $v[$_.Id] = 'falsePositive' }
        $r = Measure-MsecDefenderTriageAgreement -Alert $fpOnly -Verdict $v
        $r.TruePositiveRecall | Should -BeNullOrEmpty
        $r.Agreed             | Should -Be 8
    }

    It 'accepts alerts from the pipeline' {
        $v = @{ '9' = 'truePositive' }
        $r = $script:Alerts | Measure-MsecDefenderTriageAgreement -Verdict $v
        $r.Scored             | Should -Be 1
        $r.TruePositiveRecall | Should -Be 1
    }

    It 'emits the documented type' {
        $r = Measure-MsecDefenderTriageAgreement -Alert $script:Alerts -Verdict @{ '1' = 'falsePositive' }
        $r.PSObject.TypeNames | Should -Contain 'MsecDefenderTriageAgreement'
    }
}
