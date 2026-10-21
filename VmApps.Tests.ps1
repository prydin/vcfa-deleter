# Pester 3.4 tests; VCF APIs/deletion actions are mocked, transport uses loopback only.
Import-Module (Join-Path $PSScriptRoot 'VmApps.Common.psm1') -DisableNameChecking
if (-not ('VmApps.Tests.HttpServer' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'VmApps.TestHttpServer.cs')
}

InModuleScope VmApps.Common {
    Describe 'PowerShell VM Apps parity' {
        function New-TestVm {
            param([string]$Id = 'a', [string]$Status = 'MISSING', [hashtable]$Properties = @{})
            $props = @{
                resourceId = $Id; resourceName = "vm-$Id"; powerState = 'ON'
                zone = 'cluster / pool'; computeHostRef = 'ResourcePool:pool-1'
                endpointId = 'account-1'; datacenter = 'dc-1'; vcUuid = 'vc-1'
            }
            foreach ($key in $Properties.Keys) { $props[$key] = $Properties[$key] }
            return [pscustomobject]@{
                id = $Id; name = 'Blueprint_component'; type = 'Cloud.vSphere.Machine'
                syncStatus = $Status; properties = [pscustomobject]$props
            }
        }
        function New-TestRow {
            param([string]$Id = 'a', [string]$Deployment = 'dep-1')
            return [pscustomobject][ordered]@{
                vm_name = "vm-$Id"; deployment_name = 'App'; status = 'missing'
                vm_id = $Id; resource_id = $Id; deployment_id = $Deployment
                cloudzone = 'Production'; cloudzone_id = 'zone-1'
                powerStatus = 'ON'
            }
        }
        function New-TestTarget {
            param([string]$Id = 'dep-1', [object[]]$Rows = @((New-TestRow)))
            return [pscustomobject]@{ DeploymentId = $Id; Rows = $Rows }
        }
        function Get-TestInventory {
            param($Client, [string]$CloudZone, [switch]$All)
            $path = Join-Path $TestDrive ('inventory-' + [guid]::NewGuid().ToString('N') + '.csv')
            $writer = Open-VmCsv $path
            try { $result = Get-VmInventory $Client $CloudZone $writer -All:$All }
            finally { Close-VmCsv $writer }
            Add-Member -InputObject $result -NotePropertyName Rows -NotePropertyValue @(Import-Csv $path)
            return $result
        }
        function Set-TestReply {
            param([string]$Path, [object[]]$Replies)
            $queue = [Collections.Generic.Queue[object]]::new()
            foreach ($reply in $Replies) { $queue.Enqueue($reply) }
            $script:Replies[$Path] = $queue
        }
        function Set-TestResources {
            param([object[]]$Resources = @((New-TestVm)))
            $script:Replies = @{}
            Set-TestReply '/iaas/api/zones' @(@{ content = @($script:Zone); totalElements = 1 })
            Set-TestReply '/iaas/api/zones/zone-1' @($script:Zone)
            Set-TestReply '/deployment/api/deployments' @(@{ content = @(@{ id = 'dep-1'; name = 'App' }); last = $true })
            Set-TestReply '/deployment/api/deployments/dep-1' @(@{ id = 'dep-1'; name = 'App' })
            Set-TestReply $script:ResourcePath @(
                @{ content = $Resources; last = $true }, @{ content = $Resources; last = $true })
            Set-TestReply '/iaas/api/regions/region-1' @(@{ cloudAccountId = 'account-1'; externalRegionId = 'dc-1' })
            Set-TestReply '/iaas/api/zones/zone-1/computes' @(@{
                content = @(@{
                    id = 'compute-1'; type = 'ResourcePool'; externalId = 'pool-1'
                    externalRegionId = 'dc-1'; customProperties = @{ vcUuid = 'vc-1' }
                }); totalElements = 1
            })
            foreach ($resource in $Resources) {
                Set-TestReply ($script:ResourcePath + '/' + $resource.id) @($resource)
            }
        }
        BeforeEach {
            $script:Zone = [pscustomobject]@{
                id = 'zone-1'; name = 'Production'
                _links = @{ region = @{ href = '/iaas/api/regions/region-1' } }
            }
            $script:ResourcePath = '/deployment/api/deployments/dep-1/resources'
            $script:Calls = [Collections.Generic.List[object]]::new()
            $script:Client = [pscustomobject]@{ PageSize = 100 }
            Set-TestResources
            Mock Write-VmLog {}
            Mock Get-VmRecord {
                param($Client, $Path, $Query)
                $script:Calls.Add(@{ Path = $Path; Query = $Query })
                if (-not $script:Replies.ContainsKey($Path) -or -not $script:Replies[$Path].Count) {
                    throw "Unexpected GET $Path"
                }
                $reply = $script:Replies[$Path].Dequeue()
                if ($reply -is [Exception]) { throw $reply }
                return $reply
            }
        }

        It 'reads only top-level syncStatus, ignoring powerState and guessed fields' {
            (Get-VmSyncStatus (New-TestVm)) | Should Be 'missing'
            (Get-VmSyncStatus (New-TestVm -Status 'MiSsInG')) | Should Be 'missing'
            (Get-VmSyncStatus (New-TestVm -Status 'SUCCESS' -Properties @{ powerState = 'MISSING'; missing = $true })) | Should Be 'SUCCESS'
            (Get-VmSyncStatus @{ id = 'a'; syncState = 'MISSING'; properties = @{ syncStatus = 'MISSING' } }) | Should Be 'unknown'
            (Get-VmSyncStatus @{ id = 'a'; syncStatus = 12 }) | Should Be 'unknown'
            Assert-MockCalled Write-VmLog -Times 2 -Exactly -ParameterFilter { $Level -eq 'WARNING' }
        }

        It 'exports powerStatus from the fresh recorded powerState independently of syncStatus' {
            $resource = New-TestVm -Properties @{ powerState = 'OFF' }
            Set-TestReply ($script:ResourcePath + '/a') @($resource)
            $row = (Get-TestInventory $script:Client Production).Rows[0]
            $row.powerStatus | Should Be 'OFF'
            $row.status | Should Be 'missing'
            foreach ($value in @($null, '', 12)) {
                (Get-VmPowerStatus (New-TestVm -Properties @{ powerState = $value })) | Should Be 'unknown'
            }
            (Get-VmPowerStatus @{ id = 'a'; powerStatus = 'ON'; properties = @{ powerStatus = 'OFF' } }) | Should Be 'unknown'
        }

        It 'uses exact zone IDs, links and names with ID precedence' {
            (Get-VmZoneMembership @{ zoneId = 'zone-1' } $script:Zone) | Should Be $true
            (Get-VmZoneMembership @{ cloudZoneId = 'other'; zone = 'Production' } $script:Zone) | Should Be $false
            (Get-VmZoneMembership @{ zone = 'production' } $script:Zone) | Should Be $false
            (Get-VmZoneMembership @{ _links = @{ zone = @{ href = '/iaas/api/zones/zone-1' } } } $script:Zone) | Should Be $true
            $null -eq (Get-VmZoneMembership (New-TestVm) $script:Zone) | Should Be $true
            $null -eq (Get-VmZoneMembership @{ zone = 'Production' } $script:Zone -AllowNames $false) | Should Be $true
            { Get-VmZoneMembership @{ zoneId = 'zone-1'; properties = @{ zoneId = 'other' } } $script:Zone } | Should Throw 'Conflicting'
        }

        It 'continues on capped short IaaS and Spring pages' {
            Set-TestReply '/iaas/api/zones' @(
                @{ content = @(@{ id = 'a' }); totalElements = 2 },
                @{ content = @(@{ id = 'b' }); totalElements = 2 })
            @(Get-VmRecords $script:Client '/iaas/api/zones').Count | Should Be 2
            $script:Calls[1].Query['$skip'] | Should Be 1
            Set-TestReply '/deployment/api/deployments' @(
                @{ content = @(@{ id = 'a' }); last = $false },
                @{ content = @(@{ id = 'b' }); last = $true })
            @(Get-VmRecords $script:Client '/deployment/api/deployments').Count | Should Be 2
            $script:Calls[3].Query.page | Should Be 1
        }

        It 'rejects repeated IDs and truncated pagination' {
            Set-TestReply '/iaas/api/zones' @(
                @{ content = @(@{ id = 'a' }) }, @{ content = @(@{ id = 'a' }) })
            { Get-VmRecords $script:Client '/iaas/api/zones' } | Should Throw 'repeated ID'
            Set-TestReply '/deployment/api/deployments' @(
                @{ content = @(@{ id = 'a' }); totalElements = 3; last = $true })
            { Get-VmRecords $script:Client '/deployment/api/deployments' } | Should Throw 'before totalElements'
            Set-TestReply '/iaas/api/zones' @(@{ content = @(); totalElements = 1 })
            { Get-VmRecords $script:Client '/iaas/api/zones' } | Should Throw 'before totalElements'
            Set-TestReply '/iaas/api/zones' @(@{})
            { Get-VmRecords $script:Client '/iaas/api/zones' } | Should Throw 'content array'
        }

        It 'exports Missing only by default using fresh resource details' {
            Set-TestResources @((New-TestVm -Status 'SUCCESS'), (New-TestVm b), (New-TestVm c -Status 'SUCCESS'))
            Set-TestReply ($script:ResourcePath + '/a') @((New-TestVm))
            Set-TestReply ($script:ResourcePath + '/b') @((New-TestVm b -Status 'SUCCESS'))
            $result = Get-TestInventory $script:Client Production
            $result.Rows.Count | Should Be 1
            $result.Rows[0].vm_id | Should Be a
            $result.Rows[0].status | Should Be missing
            $result.Unverified | Should Be 0
            @($script:Calls | Where-Object { $_.Path -like '/iaas/api/machines*' }).Count | Should Be 0
        }

        It 'logs an unreadable deployment resource list and continues with an incomplete result' {
            $message = "$script:ResourcePath`: HTTP 403"
            Set-TestReply $script:ResourcePath @([VmApiException]::new('GET', $script:ResourcePath, 403))
            $result = Get-TestInventory $script:Client Production
            $result.Rows.Count | Should Be 0
            $result.Unverified | Should Be 0
            $result.IncompleteDeployments | Should Be 1
            Assert-MockCalled Write-VmLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'ERROR' -and $Message -like "*$message*"
            }
        }

        It 'logs malformed VM detail responses and excludes those VMs without aborting inventory' {
            Set-TestResources @((New-TestVm))
            Set-TestReply ($script:ResourcePath + '/a') @(
                [VmInventoryException]::new("$script:ResourcePath/a`: invalid JSON response"))
            $result = Get-TestInventory $script:Client Production
            $result.Rows.Count | Should Be 0
            $result.Unverified | Should Be 1
            Assert-MockCalled Write-VmLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'ERROR' -and $Message -like '*invalid JSON response*'
            }
        }

        It 'exports all synchronization statuses without discovered VMs' {
            Set-TestResources @((New-TestVm), (New-TestVm b -Status SUCCESS), (New-TestVm c -Status ''))
            $result = Get-TestInventory $script:Client Production -All
            ($result.Rows.status -join ',') | Should Be 'missing,SUCCESS,unknown'
            $script:Calls.Count | Should Be 9
        }

        It 'checks every compute reference and caches placement only within a run' {
            Set-TestResources @((New-TestVm), (New-TestVm b -Properties @{ endpointId = 'other' }),
                (New-TestVm c -Properties @{ datacenter = 'other' }), (New-TestVm d -Properties @{ computeHostRef = 'ResourcePool:other' }))
            $result = Get-TestInventory $script:Client Production
            $result.Rows.Count | Should Be 1
            $result.Rows[0].vm_id | Should Be a
            @($script:Calls | Where-Object { $_.Path -like '*/computes' }).Count | Should Be 1
        }

        It 'verifies Aria region-name placement in inventory and deletion without weakening compute checks' {
            foreach ($overrides in @(
                @{}, @{ region = 'other' }, @{ endpointId = 'other' },
                @{ computeHostRef = 'ResourcePool:other' }, @{ datacenter = 'other' }
            )) {
                $props = @{ datacenter = ''; region = 'vcf-lab-dc-01' }
                foreach ($key in $overrides.Keys) { $props[$key] = $overrides[$key] }
                $resource = New-TestVm -Properties $props
                Set-TestResources @($resource)
                Set-TestReply '/iaas/api/regions/region-1' @(@{
                    name = 'vcf-lab-dc-01'; externalRegionId = 'dc-1'; cloudAccountId = 'account-1'
                })
                $result = Get-TestInventory $script:Client Production
                $result.Unverified | Should Be 0
                if ($overrides.Count) { $result.Rows.Count | Should Be 0 }
                else { $result.Rows.Count | Should Be 1 }
                Set-TestResources @($resource)
                Set-TestReply '/iaas/api/regions/region-1' @(@{
                    name = 'vcf-lab-dc-01'; externalRegionId = 'dc-1'; cloudAccountId = 'account-1'
                })
                if ($overrides.Count) {
                    { Assert-VmTarget $script:Client (New-TestTarget) } | Should Throw 'no longer connected'
                } else { Assert-VmTarget $script:Client (New-TestTarget) }
            }
        }

        It 'does not infer membership from a region name without all remaining placement evidence' {
            foreach ($overrides in @(@{ region = '' }, @{ endpointId = '' }, @{ vcUuid = '' })) {
                $props = @{ datacenter = ''; region = 'vcf-lab-dc-01' }
                foreach ($key in $overrides.Keys) { $props[$key] = $overrides[$key] }
                Set-TestResources @((New-TestVm -Properties $props))
                Set-TestReply '/iaas/api/regions/region-1' @(@{
                    name = 'vcf-lab-dc-01'; externalRegionId = 'dc-1'; cloudAccountId = 'account-1'
                })
                $result = Get-TestInventory $script:Client Production
                $result.Unverified | Should Be 1
                $result.Rows.Count | Should Be 0
            }
            foreach ($conflict in @('externalRegionId', 'vcUuid')) {
                Set-TestResources @((New-TestVm -Properties @{ datacenter = ''; region = 'vcf-lab-dc-01' }))
                Set-TestReply '/iaas/api/regions/region-1' @(@{
                    name = 'vcf-lab-dc-01'; externalRegionId = 'dc-1'; cloudAccountId = 'account-1'
                })
                $compute = @{
                    id = 'compute-1'; type = 'ResourcePool'; externalId = 'pool-1'
                    externalRegionId = 'dc-1'; customProperties = @{ vcUuid = 'vc-1' }
                }
                if ($conflict -eq 'vcUuid') { $compute.customProperties.vcUuid = 'other' }
                else { $compute.externalRegionId = 'other' }
                Set-TestReply '/iaas/api/zones/zone-1/computes' @(@{ content = @($compute); totalElements = 1 })
                { Get-TestInventory $script:Client Production } | Should Throw
            }
        }

        It 'supports provider cluster aliases and rejects conflicting vCenter evidence' {
            Set-TestReply '/iaas/api/zones/zone-1/computes' @(@{
                content = @(@{ id = 'x'; type = 'Cluster'; externalId = 'domain-1'
                    externalRegionId = 'dc-1'; customProperties = @{ vcUuid = 'vc-1' } }); totalElements = 1
            })
            (Get-VmComputeMembership $script:Client (New-TestVm -Properties @{ computeHostRef = 'ClusterComputeResource:domain-1' }) $script:Zone (New-VmPlacementCache)) | Should Be $true
            Set-TestResources
            { Get-VmComputeMembership $script:Client (New-TestVm -Properties @{ vcUuid = 'other' }) $script:Zone (New-VmPlacementCache) } | Should Throw 'different vCenters'
        }

        It 'marks unverified membership and resource 404 as incomplete, not Missing' {
            Set-TestResources @((New-TestVm -Properties @{ computeHostRef = ''; zone = '' }))
            $result = Get-TestInventory $script:Client Production
            $result.Rows.Count | Should Be 0
            $result.Unverified | Should Be 1
            Set-TestResources
            Set-TestReply ($script:ResourcePath + '/a') @([VmApiException]::new('GET', 'resource', 404))
            $result = Get-TestInventory $script:Client Production
            $result.Unverified | Should Be 1
            $result.Rows.Count | Should Be 0
        }

        It 'fetches only the individual machine when its real name is missing' {
            Set-TestResources @((New-TestVm -Properties @{ resourceName = '' }))
            Set-TestReply '/iaas/api/machines/a' @(@{ id = 'a'; name = 'actual-vm' })
            (Get-TestInventory $script:Client Production).Rows[0].vm_name | Should Be 'actual-vm'
        }

        It 'rejects changed resource identities and duplicate VM associations' {
            Set-TestReply ($script:ResourcePath + '/a') @((New-TestVm other))
            { Get-TestInventory $script:Client Production } | Should Throw 'identity/type changed'
            Set-TestResources @((New-TestVm), (New-TestVm b -Properties @{ resourceId = 'a' }))
            { Get-TestInventory $script:Client Production } | Should Throw 'multiple deployment resources'
        }

        It 'writes BOM CSV with stable columns, quotes and Unicode and reads it back' {
            $path = Join-Path $TestDrive 'roundtrip.csv'
            $row = New-TestRow
            $row.vm_name = "vm,`"one`"`n$([char]0x00e9)"
            Write-VmCsv $path @($row)
            $bytes = [IO.File]::ReadAllBytes($path)
            ($bytes[0..2] -join ',') | Should Be '239,187,191'
            $targets = @(Read-VmTargets $path)
            $targets.Count | Should Be 1
            $targets[0].Rows[0].vm_name | Should Be $row.vm_name
            $targets[0].Rows[0].powerStatus | Should Be ON
            (Import-Csv $path).powerStatus | Should Be ON
            Write-VmCsv $path @()
            @(Read-VmTargets $path).Count | Should Be 0
            ([IO.File]::ReadAllLines($path)).Count | Should Be 1
        }

        It 'accepts older CSVs without powerStatus and treats empty powerStatus as unknown' {
            $path = Join-Path $TestDrive 'old.csv'
            $columns = @($script:VmColumns | Where-Object { $_ -cne 'powerStatus' })
            $row = New-TestRow
            $values = foreach ($column in $columns) { Get-VmText $row $column }
            [IO.File]::WriteAllText($path, ((ConvertTo-VmCsvLine $columns) + "`n" + (ConvertTo-VmCsvLine $values)))
            $target = @(Read-VmTargets $path)[0]
            $target.Rows[0].powerStatus | Should Be unknown
            Assert-VmTarget $script:Client $target
            $row.powerStatus = ''
            Write-VmCsv $path @($row)
            @(Read-VmTargets $path)[0].Rows[0].powerStatus | Should Be unknown
        }

        It 'rejects legacy, duplicate, malformed and cross-zone CSVs before actions' {
            $path = Join-Path $TestDrive 'bad.csv'
            [IO.File]::WriteAllText($path, "vm_name,deployment_name,status`nvm,App,missing`n")
            { Read-VmTargets $path } | Should Throw 'enriched'
            Write-VmCsv $path @((New-TestRow), (New-TestRow))
            { Read-VmTargets $path } | Should Throw 'duplicate VM'
            $row = New-TestRow b
            $row.cloudzone_id = 'other'
            Write-VmCsv $path @((New-TestRow), $row)
            { Read-VmTargets $path } | Should Throw 'spans multiple'
            $header = ConvertTo-VmCsvLine $script:VmColumns
            [IO.File]::WriteAllText($path, "$header`nvm,App,missing`n")
            { Read-VmTargets $path } | Should Throw 'column count'
            [IO.File]::WriteAllText($path, "$header`n`"unterminated`n")
            { Read-VmTargets $path } | Should Throw
        }

        It 'checks all VMs afresh and ignores CSV status as evidence' {
            $row = New-TestRow
            $row.status = 'SUCCESS'
            $row.powerStatus = 'ON'
            Assert-VmTarget $script:Client (New-TestTarget -Rows @($row))
            @($script:Calls | Where-Object { $_.Path -eq $script:ResourcePath }).Count | Should Be 2
            Set-TestResources @((New-TestVm), (New-TestVm b -Status SUCCESS -Properties @{ powerState = 'OFF' }))
            { Assert-VmTarget $script:Client (New-TestTarget -Rows @((New-TestRow), (New-TestRow b))) } | Should Throw 'syncStatus is not Missing'
        }

        It 'rejects extra, absent, empty and changed deployment resource sets' {
            Set-TestResources @((New-TestVm), (New-TestVm b))
            { Assert-VmTarget $script:Client (New-TestTarget) } | Should Throw 'VM set differs'
            Set-TestResources @()
            { Assert-VmTarget $script:Client (New-TestTarget) } | Should Throw 'VM set differs'
            Set-TestResources
            Set-TestReply $script:ResourcePath @(
                @{ content = @((New-TestVm)); last = $true },
                @{ content = @((New-TestVm), @{ id = 'disk'; type = 'Cloud.vSphere.Disk' }); last = $true })
            { Assert-VmTarget $script:Client (New-TestTarget) } | Should Throw 'changed during validation'
        }

        It 'fails closed for missing syncStatus, name-only zones and conflicting compute evidence' {
            $resource = New-TestVm
            $resource.PSObject.Properties.Remove('syncStatus')
            $resource | Add-Member NoteProperty state MISSING
            Set-TestResources @($resource)
            { Assert-VmTarget $script:Client (New-TestTarget) } | Should Throw 'syncStatus is not Missing'
            Set-TestResources @((New-TestVm -Properties @{ computeHostRef = ''; zone = 'Production' }))
            { Assert-VmTarget $script:Client (New-TestTarget) } | Should Throw 'cannot be verified'
            Set-TestResources @((New-TestVm -Properties @{ zoneId = 'zone-1'; endpointId = 'other' }))
            { Assert-VmTarget $script:Client (New-TestTarget) } | Should Throw 'no longer connected'
        }

        It 'accepts explicit zone ID without compute reference and non-VM resources' {
            Set-TestResources @((New-TestVm -Properties @{ computeHostRef = ''; zoneId = 'zone-1' }),
                @{ id = 'disk'; type = 'Cloud.vSphere.Disk' })
            Assert-VmTarget $script:Client (New-TestTarget)
        }

        Context 'dry-run scheduler' {
            It 'never submits or polls in default dry run' {
                Mock Submit-VmDelete { throw 'must not submit' }
                Mock Get-VmDeletionOutcome { throw 'must not poll' }
                $stats = Invoke-VmDeletionQueue $script:Client @((New-TestTarget))
                $stats.Eligible | Should Be 1
                $stats.Submitted | Should Be 0
                Assert-MockCalled Submit-VmDelete -Times 0 -Exactly
                Assert-MockCalled Get-VmDeletionOutcome -Times 0 -Exactly
                Assert-MockCalled Write-VmLog -Times 1 -ParameterFilter { $Message -like '*would be deleted; no delete submitted*' }
            }
        }

        Context 'five-slot scheduler' {
            It 'fills five slots, polls them and refills without threads' {
                $script:Active = New-VmSet
                $script:MaximumActive = 0
                Mock Assert-VmTarget {}
                Mock Submit-VmDelete {
                    param($Client, $Target)
                    [void]$script:Active.Add($Target.DeploymentId)
                    $script:MaximumActive = [Math]::Max($script:MaximumActive, $script:Active.Count)
                    return $Target.DeploymentId
                }
                Mock Get-VmDeletionOutcome {
                    param($Client, $Outstanding)
                    [void]$script:Active.Remove($Outstanding.RequestId)
                    return 'successful'
                }
                Mock Wait-VmPoll { throw 'should refill immediately' }
                $targets = @(0..12 | ForEach-Object { New-TestTarget "d$_" })
                $stats = Invoke-VmDeletionQueue $script:Client $targets -Execute
                $script:MaximumActive | Should Be 5
                $stats.Successful | Should Be 13
                Assert-MockCalled Assert-VmTarget -Times 13 -Exactly
            }
        }

        Context 'scheduler timeout' {
            It 'keeps polling errors occupying slots until monotonic timeout and then refills' {
                $script:Clock = 0.0
                Mock Get-VmMonotonicTime { return $script:Clock }
                Mock Wait-VmPoll { param($Seconds) $script:Clock += $Seconds }
                Mock Assert-VmTarget {}
                Mock Submit-VmDelete { param($Client, $Target) return $Target.DeploymentId }
                Mock Get-VmDeletionOutcome { throw [VmApiException]::new('GET', 'request', 404) }
                $stats = Invoke-VmDeletionQueue $script:Client @((New-TestTarget d1), (New-TestTarget d2)) `
                    -Execute -Parallel 1 -PollInterval 2 -RequestTimeout 5
                $stats.TimedOut | Should Be 2
                $stats.Failures | Should Be 2
                $stats.Successful | Should Be 0
                $script:Clock | Should Be 10
                Assert-MockCalled Submit-VmDelete -Times 2 -Exactly
            }
        }

        Context 'scheduler failure accounting' {
            It 'separates skips and failures and does not retry ambiguous submissions' {
                $script:CheckCount = 0
                Mock Assert-VmTarget {
                    $script:CheckCount++
                    if ($script:CheckCount -eq 1) { throw [VmCheckFailedException]::new('not missing') }
                    if ($script:CheckCount -eq 2) { throw [VmInventoryException]::new('unreadable') }
                }
                Mock Submit-VmDelete { throw [VmInventoryException]::new('connection lost') }
                $stats = Invoke-VmDeletionQueue $script:Client @((New-TestTarget d1), (New-TestTarget d2), (New-TestTarget d3)) -Execute
                $stats.Skipped | Should Be 1
                $stats.Failures | Should Be 2
                Assert-MockCalled Submit-VmDelete -Times 1 -Exactly
            }
        }

        Context 'duplicate request IDs' {
            It 'counts terminal failures and guards against duplicate request IDs' {
                Mock Assert-VmTarget {}
                Mock Submit-VmDelete { return 'r' }
                Mock Get-VmDeletionOutcome { return 'failed' }
                $stats = Invoke-VmDeletionQueue $script:Client @((New-TestTarget d1), (New-TestTarget d2)) -Execute
                $stats.Submitted | Should Be 1
                $stats.Failures | Should Be 2
            }
        }

        It 'requires deployment 404 after successful request, not request 404' {
            $outstanding = [pscustomobject]@{ Target = New-TestTarget; RequestId = 'r'; Started = 0 }
            Set-TestReply '/deployment/api/requests/r' @(
                @{ id = 'r'; status = 'SUCCESSFUL' }, @{ id = 'r'; status = 'SUCCESSFUL' },
                [VmApiException]::new('GET', 'request', 404))
            Set-TestReply '/deployment/api/deployments/dep-1' @(
                @{ id = 'dep-1' }, [VmApiException]::new('GET', 'deployment', 404))
            (Get-VmDeletionOutcome $script:Client $outstanding) | Should Be pending
            (Get-VmDeletionOutcome $script:Client $outstanding) | Should Be successful
            { Get-VmDeletionOutcome $script:Client $outstanding } | Should Throw 'HTTP 404'
        }

        It 'handles all terminal failures, pending statuses and identity mismatches' {
            $outstanding = [pscustomobject]@{ Target = New-TestTarget; RequestId = 'r'; Started = 0 }
            foreach ($status in @('FAILED', 'ABORTED', 'APPROVAL_REJECTED', 'CANCELLED', 'CANCELED')) {
                Set-TestReply '/deployment/api/requests/r' @(@{ id = 'r'; status = $status })
                (Get-VmDeletionOutcome $script:Client $outstanding) | Should Be failed
            }
            foreach ($status in @('INPROGRESS', 'COMPLETION', 'NEW_STATUS')) {
                Set-TestReply '/deployment/api/requests/r' @(@{ id = 'r'; status = $status })
                (Get-VmDeletionOutcome $script:Client $outstanding) | Should Be pending
            }
            Set-TestReply '/deployment/api/requests/r' @(@{ id = 'other'; status = 'SUCCESSFUL' })
            { Get-VmDeletionOutcome $script:Client $outstanding } | Should Throw 'different request ID'
            Set-TestReply '/deployment/api/requests/r' @(@{ id = 'r'; deploymentId = 'other'; status = 'SUCCESSFUL' })
            { Get-VmDeletionOutcome $script:Client $outstanding } | Should Throw 'different deployment ID'
            Set-TestReply '/deployment/api/requests/r' @(@{ id = 'r'; actionId = 'Other'; status = 'SUCCESSFUL' })
            { Get-VmDeletionOutcome $script:Client $outstanding } | Should Throw 'different action'
        }

        It 'submits exactly one Deployment.Delete action with empty inputs' {
            Mock Invoke-VmRequest { return @{ Body = '{"id":"r"}' } }
            (Submit-VmDelete $script:Client (New-TestTarget)) | Should Be r
            Assert-MockCalled Invoke-VmRequest -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'POST' -and $Path -eq '/deployment/api/deployments/dep-1/requests' -and
                ($Body | ConvertFrom-Json).actionId -ceq 'Deployment.Delete' -and
                @((($Body | ConvertFrom-Json).inputs).PSObject.Properties).Count -eq 0
            }
        }
    }
}

InModuleScope VmApps.Common {
    Describe 'PowerShell authentication and HTTP request construction' {
        BeforeEach {
            $script:Options = @{
                Server = 'example.invalid'; ApiToken = 'test-token'; Username = $null; Password = $null
                Org = 'my org'; Timeout = 60; PageSize = 100
                ApiVersion = '2021-07-15'; CloudApiVersion = '40.0'
            }
            Mock Invoke-VmRequest { return @{ Body = '{"access_token":"access"}'; Headers = @{ 'x-vmware-vcloud-access-token' = 'session' } } }
            Mock Write-VmLog {}
        }
        It 'exchanges organization tokens with URL-encoded form and path' {
            $client = New-VmClient $script:Options
            $client.Token | Should Be access
            $client.Insecure | Should Be $false
            Assert-MockCalled Write-VmLog -Times 0 -Exactly -Scope It
            Assert-MockCalled Invoke-VmRequest -Times 1 -ParameterFilter {
                $Path -eq '/oauth/tenant/my%20org/token' -and $Body -eq 'grant_type=refresh_token&refresh_token=test-token' -and
                $Headers['Content-Type'] -eq 'application/x-www-form-urlencoded'
            }
        }
        It 'refreshes a bearer token after fifteen minutes for each supported auth flow' {
            $script:RefreshCalls = [Collections.Generic.List[object]]::new()
            Mock Invoke-VmRequest {
                param($Client, $Method, $Path, $Query, $Body, $Headers, $NoBearerToken, $SkipTokenRefresh)
                $script:RefreshCalls.Add([pscustomobject]@{
                    Path = $Path; Body = $Body; Headers = $Headers
                    NoBearerToken = [bool]$NoBearerToken; SkipTokenRefresh = [bool]$SkipTokenRefresh
                })
                if ($Path -eq '/cloudapi/1.0.0/sessions') {
                    return @{
                        Body = ''; Headers = @{ 'x-vmware-vcloud-access-token' = 'fresh-session' }
                    }
                }
                if ($Path -eq '/iaas/api/login') { return @{ Body = '{"token":"fresh-legacy"}'; Headers = @{} } }
                return @{ Body = '{"access_token":"fresh-oauth"}'; Headers = @{} }
            }
            foreach ($mode in @('oauth', 'legacy', 'session')) {
                $client = [pscustomobject]@{
                    Token = 'old-token'; TokenIssuedAt = [DateTime]::UtcNow.AddMinutes(-16)
                    RefreshMode = $mode; RefreshToken = 'refresh-token'
                    RefreshPath = '/oauth/tenant/my%20org/token'; SessionAuthorization = 'Basic credentials'
                    CloudApiVersion = '40.0'; ApiVersion = '2021-07-15'; Base = 'https://example.invalid'
                    Timeout = 5; Insecure = $false
                }
                Update-VmAccessTokenIfNeeded $client
                if ($mode -eq 'oauth') { $client.Token | Should Be 'fresh-oauth' }
                elseif ($mode -eq 'legacy') { $client.Token | Should Be 'fresh-legacy' }
                else { $client.Token | Should Be 'fresh-session' }
                $client.TokenIssuedAt | Should BeGreaterThan ([DateTime]::UtcNow.AddMinutes(-1))
                $lastCall = $script:RefreshCalls[$script:RefreshCalls.Count - 1]
                $lastCall.NoBearerToken | Should Be $true
                $lastCall.SkipTokenRefresh | Should Be $true
            }
            ($script:RefreshCalls.Path -join ',') | Should Be '/oauth/tenant/my%20org/token,/iaas/api/login,/cloudapi/1.0.0/sessions'
        }
        It 'uses organization-qualified Basic session authentication' {
            $script:Options.Insecure = $true
            $script:Options.ApiToken = ''
            $script:Options.Username = 'user'
            $script:Options.Password = 'test-password'
            $client = New-VmClient $script:Options
            $client.Token | Should Be session
            $client.Insecure | Should Be $true
            $expected = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('user@my org:test-password'))
            Assert-MockCalled Invoke-VmRequest -Times 1 -ParameterFilter {
                $Path -eq '/cloudapi/1.0.0/sessions' -and $Headers.Authorization -eq $expected -and
                $Headers.Accept -eq 'application/json;version=40.0'
            }
        }
        Context 'legacy refresh-token authentication' {
            It 'exchanges an Aria refresh token without Org or VCF endpoints' {
                $script:Options.Legacy = $true
                $script:Options.Org = ''
                Mock Invoke-VmRequest { return @{ Body = '{"token":"legacy-access"}'; Headers = @{} } }
                $client = New-VmClient $script:Options
                $client.Token | Should Be 'legacy-access'
                Assert-MockCalled Invoke-VmRequest -Times 1 -Exactly -ParameterFilter {
                    $Method -eq 'POST' -and $Path -eq '/iaas/api/login' -and
                    ($Body | ConvertFrom-Json).refreshToken -ceq 'test-token' -and
                    $Headers['Content-Type'] -eq 'application/json'
                }
                Assert-MockCalled Invoke-VmRequest -Times 0 -Exactly -ParameterFilter {
                    $Path -like '/oauth/*' -or $Path -like '/cloudapi/*'
                }
            }
        }
        Context 'legacy username authentication' {
            BeforeEach {
                $script:Options.Legacy = $true
                $script:Options.Org = ''
                $script:Options.ApiToken = ''
                $script:Options.Username = 'user@example.com'
                $script:Options.Password = 'test-password'
                Mock Invoke-VmRequest {
                    param($Client, $Method, $Path)
                    if ($Path -eq '/csp/gateway/am/api/login') { return @{ Body = '{"refresh_token":"refresh"}' } }
                    if ($Path -eq '/iaas/api/login') { return @{ Body = '{"token":"legacy-access"}' } }
                    throw "Unexpected authentication endpoint $Path"
                }
            }
            It 'uses optional identity Domain and sends the username unchanged' {
                foreach ($domain in @('', 'example.com')) {
                    $script:Options.Domain = $domain
                    (New-VmClient $script:Options).Token | Should Be 'legacy-access'
                }
                Assert-MockCalled Invoke-VmRequest -Times 2 -Exactly -ParameterFilter {
                    $Path -eq '/csp/gateway/am/api/login' -and $Query.ContainsKey('access_token') -and
                    $Query.access_token -ceq '' -and ($Body | ConvertFrom-Json).username -ceq 'user@example.com' -and
                    ($Body | ConvertFrom-Json).password -ceq 'test-password'
                }
                Assert-MockCalled Invoke-VmRequest -Times 1 -Exactly -ParameterFilter {
                    $Path -eq '/csp/gateway/am/api/login' -and
                    (Get-VmText ($Body | ConvertFrom-Json) domain) -ceq 'example.com'
                }
                Assert-MockCalled Invoke-VmRequest -Times 2 -Exactly -ParameterFilter {
                    $Path -eq '/iaas/api/login' -and ($Body | ConvertFrom-Json).refreshToken -ceq 'refresh'
                }
            }
            It 'prompts securely when Password is absent and accepts an unqualified username' {
                $script:Options.Username = 'configurationadmin'
                $script:Options.Password = $null
                Mock Read-Host { return (ConvertTo-SecureString 'prompted-password' -AsPlainText -Force) }
                (New-VmClient $script:Options).Token | Should Be 'legacy-access'
                Assert-MockCalled Read-Host -Times 1 -Exactly -ParameterFilter { $AsSecureString }
                Assert-MockCalled Invoke-VmRequest -Times 1 -Exactly -ParameterFilter {
                    $Path -eq '/csp/gateway/am/api/login' -and
                    ($Body | ConvertFrom-Json).username -ceq 'configurationadmin' -and
                    ($Body | ConvertFrom-Json).password -ceq 'prompted-password'
                }
            }
        }
        Context 'legacy authentication failures' {
            BeforeEach {
                $script:Options.Legacy = $true
                $script:Options.Org = ''
            }
            It 'rejects incompatible Org and Domain before sending requests' {
                $script:Options.Org = 'tenant'
                { New-VmClient $script:Options } | Should Throw 'Org is not supported'
                $script:Options.Org = ''
                $script:Options.Domain = 'example.com'
                { New-VmClient $script:Options } | Should Throw 'Domain requires'
                $script:Options.Legacy = $false
                $script:Options.ApiToken = ''
                $script:Options.Username = 'user@tenant'
                { New-VmClient $script:Options } | Should Throw 'Domain requires'
                Assert-MockCalled Invoke-VmRequest -Times 0 -Exactly
            }
            It 'rejects malformed and missing bearer tokens without fallback' {
                $script:Body = ''
                Mock Invoke-VmRequest { return @{ Body = $script:Body } }
                foreach ($body in @('not-json', '{}', '{"token":""}', '{"access_token":"wrong-field"}')) {
                    $script:Body = $body
                    { New-VmClient $script:Options } | Should Throw
                }
                Assert-MockCalled Invoke-VmRequest -Times 4 -Exactly
            }
            It 'rejects missing refresh tokens without attempting the second exchange' {
                $script:Options.ApiToken = ''
                $script:Options.Username = 'user'
                $script:Options.Password = 'test-password'
                Mock Invoke-VmRequest { return @{ Body = '{}' } }
                { New-VmClient $script:Options } | Should Throw 'refresh_token'
                Assert-MockCalled Invoke-VmRequest -Times 1 -Exactly -Scope It
                Assert-MockCalled Invoke-VmRequest -Times 0 -Exactly -Scope It -ParameterFilter { $Path -eq '/iaas/api/login' }
            }
            It 'does not retry or fall back on authentication HTTP failures' {
                Mock Invoke-VmRequest { throw [VmApiException]::new('POST', '/iaas/api/login', 401) }
                { New-VmClient $script:Options } | Should Throw 'HTTP 401'
                Assert-MockCalled Invoke-VmRequest -Times 1 -Exactly -Scope It
            }
        }
        It 'rejects conflicting credentials, missing org and unsafe origins' {
            $script:Options.Username = 'user'
            { New-VmClient $script:Options } | Should Throw 'Do not combine'
            $script:Options.Username = ''
            $script:Options.Password = 'test-password'
            { New-VmClient $script:Options } | Should Throw 'cannot be combined'
            $script:Options.Password = $null
            $script:Options.Org = ''
            { New-VmClient $script:Options } | Should Throw 'Org is required'
            $script:Options.Org = 'org'
            foreach ($server in @('http://host', 'https://user:pass@host', 'host/path', 'host?query=x')) {
                $script:Options.Server = $server
                { New-VmClient $script:Options } | Should Throw 'HTTPS hostname'
            }
        }
        It 'rejects invalid JSON and non-object response shapes' {
            { ConvertFrom-VmJson 'not json' 'response' } | Should Throw 'invalid JSON'
            { ConvertFrom-VmJson '[]' 'response' } | Should Throw 'expected a JSON object'
        }
    }
}

InModuleScope VmApps.Common {
    Describe 'Legacy command integration' {
        BeforeEach {
            $script:LegacyOptions = @{
                Server = 'example.invalid'; ApiToken = 'test-refresh'; Username = $null; Password = $null
                Org = ''; Legacy = $true; Domain = ''; Timeout = 60; PageSize = 100
                ApiVersion = '2021-07-15'; CloudApiVersion = '40.0'
            }
            Mock Invoke-VmRequest {
                param($Client, $Method, $Path)
                if ($Path -ne '/iaas/api/login') { throw "Unexpected authentication path $Path" }
                return @{ Body = '{"token":"legacy-access"}'; Headers = @{} }
            }
        }
        Context 'legacy inventory' {
            It 'authenticates before inventory and writes the same Missing-only CSV' {
                Mock Get-VmInventory {
                    param($Client, $CloudZone, $CsvWriter, $All)
                    if ($Client.Token -cne 'legacy-access' -or $All) { throw 'Incorrect authentication or filter' }
                    $row = [pscustomobject]@{
                        vm_name = 'vm'; deployment_name = 'App'; status = 'missing'; vm_id = 'a'
                        resource_id = 'a'; deployment_id = 'dep'; cloudzone = $CloudZone; cloudzone_id = 'zone'
                    }
                    Write-VmCsvRow $CsvWriter $row
                    return [pscustomobject]@{ Count = 1; Unverified = 0; IncompleteDeployments = 0 }
                }
                $path = Join-Path $TestDrive 'legacy-inventory.csv'
                (Invoke-VmInventoryCommand $script:LegacyOptions Production $path) | Should Be 0
                @(Import-Csv $path).Count | Should Be 1
                (Import-Csv $path).status | Should Be missing
                Assert-MockCalled Invoke-VmRequest -Times 1 -Exactly -Scope It
            }
        }
        Context 'legacy deletion' {
            It 'authenticates and validates without submitting unless Execute is specified' {
                Mock Read-VmTargets { return [pscustomobject]@{ DeploymentId = 'dep'; Rows = @(@{ deployment_name = 'App' }) } }
                Mock Assert-VmTarget {
                    param($Client, $Target)
                    if ($Client.Token -cne 'legacy-access') { throw 'Incorrect authentication' }
                }
                Mock Submit-VmDelete { return 'r' }
                Mock Get-VmDeletionOutcome { return 'successful' }
                $inputCsv = Join-Path $TestDrive 'legacy-input.csv'
                $log = Join-Path $TestDrive 'legacy-delete.log'
                (Invoke-VmDeleteCommand $script:LegacyOptions $inputCsv $log) | Should Be 0
                Assert-MockCalled Assert-VmTarget -Times 1 -Exactly -Scope It
                Assert-MockCalled Submit-VmDelete -Times 0 -Exactly -Scope It
                [IO.File]::ReadAllText($log) | Should Match 'would be deleted'
                (Invoke-VmDeleteCommand $script:LegacyOptions $inputCsv $log -Execute) | Should Be 0
                Assert-MockCalled Assert-VmTarget -Times 2 -Exactly -Scope It
                Assert-MockCalled Submit-VmDelete -Times 1 -Exactly -Scope It
                [IO.File]::ReadAllText($log) | Should Match 'successful=1 failures=0 skipped=0'
            }
        }
    }
}

InModuleScope VmApps.Common {
    Describe 'Command-wide TLS cleanup' {
        BeforeEach {
            $script:TlsStage = ''
            $script:ActiveCallback = $null
            Mock New-VmClient {
                param($Options)
                $script:ActiveCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
                if ($Options.Insecure) {
                    if ([object]::ReferenceEquals($script:PriorCallback, $script:ActiveCallback)) { throw 'Bypass not installed' }
                } else {
                    if (-not [object]::ReferenceEquals($script:PriorCallback, $script:ActiveCallback)) { throw 'Default changed callback' }
                }
                if ($script:TlsStage -eq 'authentication') { throw 'Authentication failed' }
                return [pscustomobject]@{ Insecure = [bool]$Options.Insecure }
            }
        }
        Context 'inventory scope' {
            It 'keeps one callback through the command and restores it on success and errors' {
                Mock Get-VmInventory {
                    param($Client, $CloudZone, $CsvWriter)
                    if (-not [object]::ReferenceEquals($script:ActiveCallback,
                        [Net.ServicePointManager]::ServerCertificateValidationCallback)) { throw 'Callback changed mid-command' }
                    if ($script:TlsStage -eq 'processing') { throw 'Inventory failed' }
                    return [pscustomobject]@{ Count = 0; Unverified = 0; IncompleteDeployments = 0 }
                }
                $original = [Net.ServicePointManager]::ServerCertificateValidationCallback
                try {
                    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $false }
                    $script:PriorCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
                    foreach ($insecure in @($false, $true)) {
                        foreach ($stage in @('success', 'authentication', 'processing')) {
                            $script:TlsStage = $stage
                            $expected = 1
                            if ($stage -eq 'success') { $expected = 0 }
                            (Invoke-VmInventoryCommand @{ Insecure = $insecure } Production (Join-Path $TestDrive 'tls.csv')) |
                                Should Be $expected
                            [object]::ReferenceEquals($script:PriorCallback,
                                [Net.ServicePointManager]::ServerCertificateValidationCallback) | Should Be $true
                        }
                    }
                } finally { [Net.ServicePointManager]::ServerCertificateValidationCallback = $original }
            }
        }
        Context 'deletion scope' {
            It 'restores the prior callback after success, authentication or scheduler failures' {
                Mock Read-VmTargets { return [pscustomobject]@{ DeploymentId = 'dep' } }
                Mock Invoke-VmDeletionQueue {
                    if (-not [object]::ReferenceEquals($script:ActiveCallback,
                        [Net.ServicePointManager]::ServerCertificateValidationCallback)) { throw 'Callback changed mid-command' }
                    if ($script:TlsStage -eq 'processing') { throw 'Scheduler failed' }
                }
                $original = [Net.ServicePointManager]::ServerCertificateValidationCallback
                try {
                    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $false }
                    $script:PriorCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
                    foreach ($insecure in @($false, $true)) {
                        foreach ($stage in @('success', 'authentication', 'processing')) {
                            $script:TlsStage = $stage
                            $expected = 1
                            if ($stage -eq 'success') { $expected = 0 }
                            $log = Join-Path $TestDrive "tls-$insecure-$stage.log"
                            (Invoke-VmDeleteCommand @{ Insecure = $insecure } (Join-Path $TestDrive 'input.csv') $log) |
                                Should Be $expected
                            [object]::ReferenceEquals($script:PriorCallback,
                                [Net.ServicePointManager]::ServerCertificateValidationCallback) | Should Be $true
                            $hasWarning = [IO.File]::ReadAllText($log).Contains('TLS certificate verification is disabled')
                            $hasWarning | Should Be $insecure
                        }
                    }
                } finally { [Net.ServicePointManager]::ServerCertificateValidationCallback = $original }
            }
        }
    }
}

InModuleScope VmApps.Common {
    Describe 'Native request failure cleanup' {
        It 'restores a preexisting callback after a connection failure without leaking exception details' {
            $originalProgressPreference = $ProgressPreference
            $script:RequestProgressPreference = $null
            Mock Invoke-WebRequest {
                $script:RequestProgressPreference = $ProgressPreference
                throw [Net.WebException]::new('sensitive-connection-details')
            }
            $original = [Net.ServicePointManager]::ServerCertificateValidationCallback
            try {
                $ProgressPreference = 'Continue'
                [Net.ServicePointManager]::ServerCertificateValidationCallback = { $false }
                $prior = [Net.ServicePointManager]::ServerCertificateValidationCallback
                $client = [pscustomobject]@{ Base = 'https://example.invalid'; ApiVersion = ''; Token = ''; Timeout = 5 }
                { Invoke-VmRequest $client GET '/test' } | Should Throw 'GET /test: connection/TLS failure'
                $script:RequestProgressPreference | Should Be 'SilentlyContinue'
                $ProgressPreference | Should Be 'Continue'
                [object]::ReferenceEquals($prior,
                    [Net.ServicePointManager]::ServerCertificateValidationCallback) | Should Be $true
            } finally {
                $ProgressPreference = $originalProgressPreference
                [Net.ServicePointManager]::ServerCertificateValidationCallback = $original
            }
        }

        It 'logs API call timing only in debug mode and never logs credential query values' {
            $script:Logged = @()
            Mock Write-VmLog { $script:Logged += "${Level}: $Message" }
            Mock Invoke-WebRequest { throw [Net.WebException]::new('down') }
            $client = [pscustomobject]@{ Base = 'https://example.invalid'; ApiVersion = ''; Token = ''; Timeout = 5; Debug = $false }
            { Invoke-VmRequest $client GET '/quiet' } | Should Throw
            $script:Logged.Count | Should Be 0
            $client.Debug = $true
            { Invoke-VmRequest $client POST '/login' -Query @{ access_token = 'secret'; page = 2 } } | Should Throw
            $script:Logged.Count | Should Be 1
            $script:Logged[0] | Should Match '^DEBUG: POST /login\?page=2 -> connection/TLS failure in [\d,]+ ms$'
            $script:Logged[0] | Should Not Match 'secret'
        }
    }
}

Describe 'PowerShell transport and native entry points' {
    It 'sends an actual loopback POST and decodes the response without redirects' {
        $server = [VmApps.Tests.HttpServer]::new(200, '{"content":[{"id":"a"}],"totalElements":1}')
        try {
            $client = [pscustomobject]@{
                Base = $server.Url.TrimEnd('/'); ApiVersion = '2021-07-15'; Token = 'test-access'
                Timeout = 5
            }
            $reply = Invoke-VmRequest $client POST '/iaas/test' -Query @{ '$skip' = 3 } `
                -Body '{"actionId":"test"}' -Headers @{ 'Content-Type' = 'application/json' }
            $record = ConvertFrom-VmJson $reply.Body test
            $record.content[0].id | Should Be a
            $server.Request | Should Match 'POST /iaas/test\?'
            $server.Request | Should Match 'apiVersion=2021-07-15'
            $server.Request | Should Match '%24skip=3'
            $server.Request | Should Match 'Authorization: Bearer test-access'
            $server.Request | Should Match '\{"actionId":"test"\}'
        } finally { $server.Dispose() }
    }
    It 'treats HTTP errors and redirects as errors without leaking server bodies' {
        foreach ($status in @(404, 302)) {
            $server = [VmApps.Tests.HttpServer]::new($status, 'sensitive-server-body')
            try {
                $client = [pscustomobject]@{ Base = $server.Url.TrimEnd('/'); ApiVersion = ''; Token = ''; Timeout = 5 }
                $previousCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
                $failure = $null
                try { Invoke-VmRequest $client GET '/test' }
                catch { $failure = Get-VmFailure $_.Exception }
                $failure.Status | Should Be $status
                $failure.Message | Should Be "GET /test: HTTP $status"
                [object]::ReferenceEquals($previousCallback,
                    [Net.ServicePointManager]::ServerCertificateValidationCallback) | Should Be $true
            } finally { $server.Dispose() }
        }
    }
    It 'refuses absolute or scheme-relative API paths before any network request' {
        { Invoke-VmRequest $null GET 'https://elsewhere/test' } | Should Throw 'relative'
        { Invoke-VmRequest $null GET '//elsewhere/test' } | Should Throw 'relative'
    }
    It 'rejects untrusted TLS by default and accepts it only inside an insecure scope' {
        $rsa = [Security.Cryptography.RSA]::Create(2048)
        $certificate = $null
        $originalCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
        try {
            $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
                'CN=localhost', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256,
                [Security.Cryptography.RSASignaturePadding]::Pkcs1)
            $request.CertificateExtensions.Add(
                [Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true, $false, 0, $true))
            $usages = [Security.Cryptography.OidCollection]::new()
            [void]$usages.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'))
            $request.CertificateExtensions.Add(
                [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($usages, $true))
            $certificate = $request.CreateSelfSigned([DateTimeOffset]::Now.AddMinutes(-5), [DateTimeOffset]::Now.AddHours(1))
            # .NET Framework SChannel needs a temporary key container rather than an ephemeral RSA key.
            $pfx = $certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx, 'fixture')
            $certificate.Dispose()
            $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
                $pfx, 'fixture', [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::UserKeySet)
            [Net.ServicePointManager]::ServerCertificateValidationCallback = $null
            foreach ($mode in @('untrusted', 'name-mismatch')) {
              foreach ($insecure in @($false, $true)) {
                $server = [VmApps.Tests.HttpServer]::new(200, '{"ok":true}', $certificate)
                $state = $null
                try {
                    $url = $server.Url
                    if ($mode -eq 'name-mismatch') { $url = $url.Replace('localhost', '127.0.0.1') }
                    $client = [pscustomobject]@{ Base = $url.TrimEnd('/'); ApiVersion = ''; Token = ''; Timeout = 5; Insecure = $insecure }
                    $state = Start-VmTlsScope @{ Insecure = $insecure }
                    if ($insecure) {
                        (Invoke-VmRequest $client GET '/test').Body | Should Be '{"ok":true}'
                    } else {
                        { Invoke-VmRequest $client GET '/test' } | Should Throw 'connection/TLS failure'
                    }
                } finally {
                    Stop-VmTlsScope $state
                    $server.Dispose()
                }
                [Net.ServicePointManager]::ServerCertificateValidationCallback | Should BeNullOrEmpty
              }
            }
        } finally {
            [Net.ServicePointManager]::ServerCertificateValidationCallback = $originalCallback
            if ($null -ne $certificate) { $certificate.Dispose() }
            $rsa.Dispose()
        }
    }
    It 'parses all four PowerShell files and exposes native aliases' {
        foreach ($name in @('VmApps.Common.psm1', 'vm_apps_inventory.ps1', 'vm_apps_delete.ps1', 'VmApps.Tests.ps1')) {
            $tokens = $null; $errors = $null
            $null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name), [ref]$tokens, [ref]$errors)
            @($errors).Count | Should Be 0
        }
        $inventory = Get-Command (Join-Path $PSScriptRoot 'vm_apps_inventory.ps1')
        ($inventory.Parameters['Server'].Aliases -contains 'Host') | Should Be $true
        $inventory.Parameters.ContainsKey('All') | Should Be $true
        $inventory.Parameters.ContainsKey('Legacy') | Should Be $true
        $inventory.Parameters.ContainsKey('Domain') | Should Be $true
        $inventory.Parameters.ContainsKey('Insecure') | Should Be $true
        $inventory.Parameters.ContainsKey('CaBundle') | Should Be $false
        $delete = Get-Command (Join-Path $PSScriptRoot 'vm_apps_delete.ps1')
        ($delete.Parameters['InputCsv'].Aliases -contains 'Input') | Should Be $true
        $delete.Parameters.ContainsKey('Execute') | Should Be $true
        $delete.Parameters.ContainsKey('Legacy') | Should Be $true
        $delete.Parameters.ContainsKey('Domain') | Should Be $true
        $delete.Parameters.ContainsKey('DryRun') | Should Be $false
        $delete.Parameters.ContainsKey('Insecure') | Should Be $true
        $delete.Parameters.ContainsKey('CaBundle') | Should Be $false
    }
    It 'runs the actual deletion CLI as a child process for a header-only CSV without authentication' {
        $inputCsv = Join-Path $TestDrive 'empty.csv'
        $log = Join-Path $TestDrive 'empty.log'
        Write-VmCsv $inputCsv @()
        $messages = & powershell.exe -NoProfile -ExecutionPolicy Bypass -OutputFormat Text -File `
            (Join-Path $PSScriptRoot 'vm_apps_delete.ps1') -Host host -Input $inputCsv -LogFile $log 2>&1
        $LASTEXITCODE | Should Be 0
        [IO.File]::ReadAllText($log) | Should Match 'eligible=0 submitted=0'
    }
}

InModuleScope VmApps.Common {
    Describe 'PowerShell command flows with mocked APIs' {
        BeforeEach {
            Mock New-VmClient { return [pscustomobject]@{ PageSize = 100 } }
        }
        Context 'inventory CLI' {
            It 'writes Missing-only inventory by default and honors All' {
                Mock Get-VmInventory {
                    param($Client, $CloudZone, $CsvWriter, $All)
                    $rows = @([pscustomobject]@{ vm_name = 'vm'; deployment_name = 'App'; status = 'missing'
                        vm_id = 'a'; resource_id = 'a'; deployment_id = 'dep'; cloudzone = 'Production'; cloudzone_id = 'zone' })
                    if ($All) { $rows += $rows[0].PSObject.Copy(); $rows[1].status = 'SUCCESS' }
                    foreach ($row in $rows) { Write-VmCsvRow $CsvWriter $row }
                    return [pscustomobject]@{ Count = $rows.Count; Unverified = 0; IncompleteDeployments = 0 }
                }
                $path = Join-Path $TestDrive 'inventory.csv'
                (Invoke-VmInventoryCommand @{} Production $path) | Should Be 0
                @(Import-Csv $path).Count | Should Be 1
                (Invoke-VmInventoryCommand @{} Production $path -All) | Should Be 0
                @(Import-Csv $path).Count | Should Be 2
            }

            It 'preserves rows already written when a later inventory error occurs' {
                Mock Get-VmInventory {
                    param($Client, $CloudZone, $CsvWriter)
                    Write-VmCsvRow $CsvWriter ([pscustomobject]@{
                        vm_name = 'vm'; deployment_name = 'App'; status = 'missing'
                        vm_id = 'a'; resource_id = 'a'; deployment_id = 'dep'
                        cloudzone = $CloudZone; cloudzone_id = 'zone'; powerStatus = 'ON'
                    })
                    throw [VmInventoryException]::new('later deployment failed')
                }
                $path = Join-Path $TestDrive 'partial-inventory.csv'
                (Invoke-VmInventoryCommand @{} Production $path) | Should Be 1
                $rows = @(Import-Csv $path)
                $rows.Count | Should Be 1
                $rows[0].vm_id | Should Be a
            }
        }
        Context 'deletion CLI' {
            It 'defaults to dry run, persists summary and requires Execute to submit' {
                Mock Read-VmTargets { return [pscustomobject]@{ DeploymentId = 'dep'; Rows = @(@{ deployment_name = 'App' }) } }
                Mock Assert-VmTarget {}
                Mock Submit-VmDelete { return 'r' }
                Mock Get-VmDeletionOutcome { return 'successful' }
                $log = Join-Path $TestDrive 'deletion.log'
                (Invoke-VmDeleteCommand @{} (Join-Path $TestDrive 'input.csv') $log) | Should Be 0
                Assert-MockCalled Submit-VmDelete -Times 0 -Exactly
                ([IO.File]::ReadAllText($log)) | Should Match 'would be deleted; no delete submitted'
                (Invoke-VmDeleteCommand @{} (Join-Path $TestDrive 'input.csv') $log -Execute) | Should Be 0
                Assert-MockCalled Submit-VmDelete -Times 1 -Exactly
                ([IO.File]::ReadAllText($log)) | Should Match 'successful=1 failures=0 skipped=0'
            }
        }
        Context 'invalid-input CLI' {
            It 'rejects malformed input before authentication and protects the input from log overwrite' {
                Mock Read-VmTargets { throw [VmInventoryException]::new('malformed CSV') }
                $path = Join-Path $TestDrive 'input.csv'
                $log = Join-Path $TestDrive 'bad.log'
                (Invoke-VmDeleteCommand @{} $path $log) | Should Be 1
                Assert-MockCalled New-VmClient -Times 0 -Exactly
                ([IO.File]::ReadAllText($log)) | Should Match 'failures=1'
                [IO.File]::WriteAllText($path, 'existing')
                (Invoke-VmDeleteCommand @{} $path $path) | Should Be 1
                [IO.File]::ReadAllText($path) | Should Be existing
            }
        }
    }
}
