﻿# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# .DESCRIPTION
# This Exchange Online script runs the Get-CalendarDiagnosticObjects script and returns a summarized timeline of actions in clear english
# as well as the Calendar Diagnostic Objects in CSV format.
#
# .PARAMETER Identity
# One or more SMTP Address of EXO User Mailbox to query.
#
# .PARAMETER Subject
# Subject of the meeting to query, only valid if Identity is a single user.
#
# .PARAMETER MeetingID
# The MeetingID of the meeting to query.
#
# .PARAMETER TrackingLogs
# Include specific tracking logs in the output. Only useable with the MeetingID parameter.
#
# .PARAMETER Exceptions
# Include Exception objects in the output. Only useable with the MeetingID parameter.
#
# .EXAMPLE
# Get-CalendarDiagnosticObjectsSummary.ps1 -Identity someuser@microsoft.com -MeetingID 040000008200E00074C5B7101A82E008000000008063B5677577D9010000000000000000100000002FCDF04279AF6940A5BFB94F9B9F73CD
#
# Get-CalendarDiagnosticObjectsSummary.ps1 -Identity someuser@microsoft.com -Subject "Test OneTime Meeting Subject"
#
# Get-CalendarDiagnosticObjectsSummary.ps1 -Identity User1, User2, Delegate -MeetingID $MeetingID
#

[CmdletBinding(DefaultParameterSetName = 'Subject')]
param (
    [Parameter(Mandatory, Position = 0)]
    [string[]]$Identity,

    [Parameter(Mandatory, ParameterSetName = 'MeetingID', Position = 1)]
    [string]$MeetingID,
    [switch]$TrackingLogs,
    [switch]$Exceptions,

    [Parameter(Mandatory, ParameterSetName = 'Subject', Position = 1)]
    [string]$Subject
)

# ===================================================================================================
# Auto update script
# ===================================================================================================
$BuildVersion = ""
. $PSScriptRoot\..\Shared\ScriptUpdateFunctions\Test-ScriptVersion.ps1
if (Test-ScriptVersion -AutoUpdate -Confirm:$false) {
    # Update was downloaded, so stop here.
    Write-Host "Script was updated. Please rerun the command." -ForegroundColor Yellow
    return
}

Write-Verbose "Script Versions: $BuildVersion"

# ===================================================================================================
# Support scripts
# ===================================================================================================
. $PSScriptRoot\CalLogHelpers\CalLogCSVFunctions.ps1
. $PSScriptRoot\CalLogHelpers\TimelineFunctions.ps1
. $PSScriptRoot\CalLogHelpers\MeetingSummaryFunctions.ps1
. $PSScriptRoot\CalLogHelpers\Invoke-GetMailbox.ps1
. $PSScriptRoot\CalLogHelpers\Invoke-GetCalLogs.ps1
. $PSScriptRoot\CalLogHelpers\ShortClientNameFunctions.ps1
. $PSScriptRoot\CalLogHelpers\CalLogInfoFunctions.ps1
. $PSScriptRoot\CalLogHelpers\Write-DashLineBoxColor.ps1

# ===================================================================================================
# Main
# ===================================================================================================

$ValidatedIdentities = CheckIdentities -Identity $Identity

if (-not ([string]::IsNullOrEmpty($Subject)) ) {
    if ($ValidatedIdentities.count -gt 1) {
        Write-Warning "Multiple mailboxes were found, but only one is supported for Subject searches.  Please specify a single mailbox."
        exit
    }
    GetCalLogsWithSubject -Identity $ValidatedIdentities -Subject $Subject
} elseif (-not ([string]::IsNullOrEmpty($MeetingID))) {
    # Process Logs based off Passed in MeetingID
    foreach ($ID in $ValidatedIdentities) {
        Write-DashLineBoxColor "Looking for CalLogs from [$ID] with passed in MeetingID."
        Write-Verbose "Running: Get-CalendarDiagnosticObjects -Identity [$ID] -MeetingID [$MeetingID] -CustomPropertyNames $CustomPropertyNameList -WarningAction Ignore -MaxResults $LogLimit -ResultSize $LogLimit -ShouldBindToItem $true;"
        $script:GCDO = GetCalendarDiagnosticObjects -Identity $ID -MeetingID $MeetingID

        if ($script:GCDO.count -gt 0) {
            Write-Host -ForegroundColor Cyan "Found $($script:GCDO.count) CalLogs with MeetingID [$MeetingID]."
            $script:IsOrganizer = (SetIsOrganizer -CalLogs $script:GCDO)
            Write-Host -ForegroundColor Cyan "The user [$ID] $(if ($IsOrganizer) {"IS"} else {"is NOT"}) the Organizer of the meeting."
            $IsRoomMB = (SetIsRoom -CalLogs $script:GCDO)
            if ($IsRoomMB) {
                Write-Host -ForegroundColor Cyan "The user [$ID] is a Room Mailbox."
            }

            if ($Exceptions.IsPresent) {
                Write-Verbose "Looking for Exception Logs..."
                $IsRecurring = SetIsRecurring -CalLogs $script:GCDO
                Write-Verbose "Meeting IsRecurring: $IsRecurring"

                if ($IsRecurring) {
                    #collect Exception Logs
                    $ExceptionLogs = @()
                    $LogToExamine = @()
                    $LogToExamine = $script:GCDO | Where-Object { $_.ItemClass -like 'IPM.Appointment*' } | Sort-Object ItemVersion

                    Write-Host -ForegroundColor Cyan "Found $($LogToExamine.count) CalLogs to examine for Exception Logs."
                    if ($LogToExamine.count -gt 100) {
                        Write-Host -ForegroundColor Cyan "`t This is a large number of logs to examine, this may take a while."
                        Write-Host -ForegroundColor Blue "`Press Y to continue..."
                        $Answer = [console]::ReadKey($true).Key
                        if ($Answer -ne "Y") {
                            Write-Host -ForegroundColor Cyan "User chose not to continue, skipping Exception Logs."
                            $LogToExamine = $null
                        }
                    }
                    Write-Host -ForegroundColor Cyan "`t Ignore the next [$($LogToExamine.count)] warnings..."
                    $logLeftCount = $LogToExamine.count

                    $ExceptionLogs = $LogToExamine | ForEach-Object {
                        $logLeftCount -= 1
                        Write-Verbose "Getting Exception Logs for [$($_.ItemId.ObjectId)]"
                        Get-CalendarDiagnosticObjects -Identity $ID -ItemIds $_.ItemId.ObjectId -ShouldFetchRecurrenceExceptions $true -CustomPropertyNames $CustomPropertyNameList
                        if ($logLeftCount % 50 -eq 0) {
                            Write-Host -ForegroundColor Cyan "`t [$($logLeftCount)] logs left to examine..."
                        }
                    }
                    # Remove the IPM.Appointment logs as they are already in the CalLogs.
                    $ExceptionLogs = $ExceptionLogs | Where-Object { $_.ItemClass -notlike "IPM.Appointment*" }
                    Write-Host -ForegroundColor Cyan "Found $($ExceptionLogs.count) Exception Logs, adding them into the CalLogs."

                    $script:GCDO = $script:GCDO + $ExceptionLogs | Select-Object *, @{n='OrgTime'; e= { [DateTime]::Parse($_.OriginalLastModifiedTime.ToString()) } } | Sort-Object OrgTime
                    $LogToExamine = $null
                    $ExceptionLogs = $null
                } else {
                    Write-Host -ForegroundColor Cyan "No Recurring Meetings found, no Exception Logs to collect."
                }
            }

            BuildCSV -Identity $ID
            BuildTimeline -Identity $ID
        } else {
            Write-Warning "No CalLogs were found for [$ID] with MeetingID [$MeetingID]."
        }
    }
} else {
    Write-Warning "A valid MeetingID was not found, nor Subject. Please confirm the MeetingID or Subject and try again."
}

Write-DashLineBoxColor "Hope this script was helpful in getting and understanding the Calendar Logs.",
"If you have issues or suggestion for this script, please send them to: ",
"`t CalLogFormatterDevs@microsoft.com" -Color Yellow -DashChar =
