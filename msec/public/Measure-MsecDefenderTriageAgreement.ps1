function Measure-MsecDefenderTriageAgreement {
    <#
    .SYNOPSIS
        Scores proposed triage verdicts against the ones analysts actually recorded - how often
        a second opinion agrees, and, far more importantly, what it misses.

    .DESCRIPTION
        Before anything automated is allowed to classify alerts, the question is how often it
        would have agreed with the people doing it now. This answers that: feed it alerts that
        already carry a human classification and a set of proposed verdicts, and it reports
        agreement broken down by class - never as a single percentage.

        THIS COMMAND MAKES NO JUDGEMENTS AND CALLS NOTHING. It is deliberately agnostic about
        where the proposed verdicts come from - a model, a rule, a second analyst, a
        spreadsheet. msec reads and measures; deciding what an alert is belongs elsewhere, and
        wiring a particular engine in here would make the measurement untestable.

        A SINGLE ACCURACY FIGURE IS MISLEADING ON THIS DATA AND IS NOT REPORTED. Triage sets
        are heavily imbalanced - measured on one tenant, 354 falsePositive against 39
        truePositive - so a proposal that answers 'falsePositive' every time scores 89% while
        catching nothing. TruePositiveRecall is the number that decides whether automation is
        safe: the proportion of real detections the proposal also called real. A missed true
        positive is the expensive error and it is the one a headline accuracy hides.

        GROUND TRUTH IS ONLY WHERE SOMEONE ACTUALLY RECORDED ONE. Alerts whose Classification
        is 'unknown' or empty are NOT scored as disagreements - nobody judged them, so there is
        nothing to disagree with. They are counted and reported separately as Unlabelled,
        because silently dropping them would overstate how much evidence the score rests on.

        COVERAGE IS REPORTED, NOT ASSUMED. An alert with no proposed verdict and a verdict with
        no matching alert are both counted and surfaced. A proposal that simply declined to
        answer most of the set would otherwise score beautifully on the handful it did answer.

    .PARAMETER Alert
        Alerts carrying the recorded human verdict - Get-MsecDefenderAlert output. Pipe them in
        or pass an array. Exclude automation first: assignedTo values like 'Suppression rule'
        are not human verdicts.

    .PARAMETER Verdict
        The proposed classifications, as a hashtable keyed by alert Id, each value one of
        unknown / falsePositive / truePositive / informationalExpectedActivity.

    .EXAMPLE
        $labelled = Get-MsecDefenderAlert -UpdatedWithin 45 -TriagedBy 'analyst@contoso.com'
        $proposed = @{}   # built elsewhere, however you like
        Measure-MsecDefenderTriageAgreement -Alert $labelled -Verdict $proposed

    .EXAMPLE
        # The number that decides whether to automate anything.
        (Measure-MsecDefenderTriageAgreement -Alert $labelled -Verdict $proposed).TruePositiveRecall

    .OUTPUTS
        One PSCustomObject, PSTypeName 'MsecDefenderTriageAgreement'.

    .NOTES
        Read-only, and offline - it calls no API. Pair with Get-MsecDefenderAlert
        -UpdatedWithin, which is what makes a labelled set findable at all.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object[]] $Alert,

        [Parameter(Mandatory)]
        [hashtable] $Verdict
    )

    begin {
        $all = [System.Collections.Generic.List[object]]::new()
    }

    process {
        foreach ($a in $Alert) { if ($a) { $all.Add($a) } }
    }

    end {
        # 'unknown' and empty both mean nobody recorded a verdict. Neither is a disagreement.
        $labelled   = @($all | Where-Object { $_.Classification -and $_.Classification -ne 'unknown' })
        $unlabelled = @($all).Count - $labelled.Count

        $scored      = [System.Collections.Generic.List[object]]::new()
        $noVerdict   = [System.Collections.Generic.List[string]]::new()

        foreach ($a in $labelled) {
            $id = [string]$a.Id
            if (-not $Verdict.ContainsKey($id)) { $noVerdict.Add($id); continue }

            $proposed = [string]$Verdict[$id]
            $actual   = [string]$a.Classification
            $scored.Add([PSCustomObject]@{
                Id       = $id
                Title    = [string]$a.Title
                Actual   = $actual
                Proposed = $proposed
                Agreed   = ($proposed -eq $actual)
            })
        }

        # A verdict for an alert that is not in the labelled set - usually a stale id, or a
        # proposal built against a different query than the one being scored.
        $labelledIds = @{}
        foreach ($a in $labelled) { $labelledIds[[string]$a.Id] = $true }
        $orphanVerdicts = @(foreach ($k in $Verdict.Keys) { if (-not $labelledIds.ContainsKey([string]$k)) { [string]$k } })

        # Per-class recall: of the alerts an analyst called X, how many did the proposal also
        # call X. Reported per class rather than pooled, because the classes are wildly
        # imbalanced and a pooled figure hides the one that matters.
        $perClass = foreach ($class in @('truePositive', 'falsePositive', 'informationalExpectedActivity')) {
            $actualIsClass = @($scored | Where-Object { $_.Actual -eq $class })
            $caught        = @($actualIsClass | Where-Object { $_.Agreed })
            [PSCustomObject]@{
                Class  = $class
                Actual = $actualIsClass.Count
                Agreed = $caught.Count
                Recall = if ($actualIsClass.Count) { [math]::Round($caught.Count / $actualIsClass.Count, 3) } else { $null }
            }
        }

        # The disagreements, most common shape first - where a proposal is wrong is more
        # actionable than how often.
        $confusion = $scored | Where-Object { -not $_.Agreed } |
            Group-Object { "$($_.Actual) -> $($_.Proposed)" } |
            Sort-Object Count -Descending |
            ForEach-Object { [PSCustomObject]@{ Shape = $_.Name; Count = $_.Count } }

        $tp = @($perClass | Where-Object Class -eq 'truePositive')[0]

        [PSCustomObject]@{
            PSTypeName        = 'MsecDefenderTriageAgreement'
            Scored            = $scored.Count
            Agreed            = @($scored | Where-Object Agreed).Count
            Disagreed         = @($scored | Where-Object { -not $_.Agreed }).Count
            # THE NUMBER THAT DECIDES WHETHER TO AUTOMATE. Null when the labelled set contains
            # no true positives at all - which is not a pass, it is no evidence either way.
            TruePositiveRecall = $tp.Recall
            PerClass          = @($perClass)
            Confusion         = @($confusion)
            # Coverage, so a proposal that mostly declined to answer cannot look accurate.
            Unlabelled        = $unlabelled
            LabelledNoVerdict = $noVerdict.Count
            OrphanVerdicts    = @($orphanVerdicts).Count
            Detail            = @($scored)
        }
    }
}
