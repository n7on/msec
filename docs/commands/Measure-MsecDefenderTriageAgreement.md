---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Measure-MsecDefenderTriageAgreement

## SYNOPSIS
Scores proposed triage verdicts against the ones analysts actually recorded - how often
a second opinion agrees, and, far more importantly, what it misses.

## SYNTAX

```
Measure-MsecDefenderTriageAgreement [-Alert] <Object[]> [-Verdict] <Hashtable> [<CommonParameters>]
```

## DESCRIPTION
Before anything automated is allowed to classify alerts, the question is how often it
would have agreed with the people doing it now.
This answers that: feed it alerts that
already carry a human classification and a set of proposed verdicts, and it reports
agreement broken down by class - never as a single percentage.

THIS COMMAND MAKES NO JUDGEMENTS AND CALLS NOTHING.
It is deliberately agnostic about
where the proposed verdicts come from - a model, a rule, a second analyst, a
spreadsheet.
msec reads and measures; deciding what an alert is belongs elsewhere, and
wiring a particular engine in here would make the measurement untestable.

A SINGLE ACCURACY FIGURE IS MISLEADING ON THIS DATA AND IS NOT REPORTED.
Triage sets
are heavily imbalanced - measured on one tenant, 354 falsePositive against 39
truePositive - so a proposal that answers 'falsePositive' every time scores 89% while
catching nothing.
TruePositiveRecall is the number that decides whether automation is
safe: the proportion of real detections the proposal also called real.
A missed true
positive is the expensive error and it is the one a headline accuracy hides.

GROUND TRUTH IS ONLY WHERE SOMEONE ACTUALLY RECORDED ONE.
Alerts whose Classification
is 'unknown' or empty are NOT scored as disagreements - nobody judged them, so there is
nothing to disagree with.
They are counted and reported separately as Unlabelled,
because silently dropping them would overstate how much evidence the score rests on.

COVERAGE IS REPORTED, NOT ASSUMED.
An alert with no proposed verdict and a verdict with
no matching alert are both counted and surfaced.
A proposal that simply declined to
answer most of the set would otherwise score beautifully on the handful it did answer.

## EXAMPLES

### EXAMPLE 1
```
$labelled = Get-MsecDefenderAlert -UpdatedWithin 45 -TriagedBy 'analyst@contoso.com'
$proposed = @{}   # built elsewhere, however you like
Measure-MsecDefenderTriageAgreement -Alert $labelled -Verdict $proposed
```

### EXAMPLE 2
```
# The number that decides whether to automate anything.
(Measure-MsecDefenderTriageAgreement -Alert $labelled -Verdict $proposed).TruePositiveRecall
```

## PARAMETERS

### -Alert
Alerts carrying the recorded human verdict - Get-MsecDefenderAlert output.
Pipe them in
or pass an array.
Exclude automation first: assignedTo values like 'Suppression rule'
are not human verdicts.

```yaml
Type: Object[]
Parameter Sets: (All)
Aliases:

Required: True
Position: 1
Default value: None
Accept pipeline input: True (ByValue)
Accept wildcard characters: False
```

### -Verdict
The proposed classifications, as a hashtable keyed by alert Id, each value one of
unknown / falsePositive / truePositive / informationalExpectedActivity.

```yaml
Type: Hashtable
Parameter Sets: (All)
Aliases:

Required: True
Position: 2
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### One PSCustomObject, PSTypeName 'MsecDefenderTriageAgreement'.
## NOTES
Read-only, and offline - it calls no API.
Pair with Get-MsecDefenderAlert
-UpdatedWithin, which is what makes a labelled set findable at all.

## RELATED LINKS
