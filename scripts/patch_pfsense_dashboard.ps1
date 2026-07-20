$path = "C:\Users\nas\Desktop\Projekti\GIT\ansible_scripts\update\roles\grafana\files\pfsense-flux.json"
$j = Get-Content $path -Raw | ConvertFrom-Json

foreach ($k in '__inputs','__elements','__requires') {
    if ($j.PSObject.Properties[$k]) { $j.PSObject.Properties.Remove($k) }
}

# Remove pfBlocker panels, Temperature, Gateway panels, empty LAN row
$dropIds = @(525,160,716,642,563,718,717,719,103,4,487,43)
$j.panels = @($j.panels | Where-Object { $dropIds -notcontains $_.id })

# Shift y-positions to compress vertical gap left by removed pfBlocker (was y=13..22, h=10 total)
foreach ($p in $j.panels) {
    if ($p.gridPos.y -ge 23) { $p.gridPos.y -= 10 }
}

# --- Templating: rewrite to Flux ---
$dsUid = '__INFLUXDB_PFSENSE_UID__'
$ds = @{ type='influxdb'; uid=$dsUid }

function TagValuesVar($name, $label, $tag, $measurement, $extraPredicate='', $multi=$false, $includeAll=$false) {
    $pred = "r._measurement == `"$measurement`""
    if ($extraPredicate) { $pred = "$pred and $extraPredicate" }
    $q = @"
import "influxdata/influxdb/schema"
schema.tagValues(bucket: "pfsense", tag: "$tag", predicate: (r) => $pred)
"@
    # allValue=".+" so ${var:regex} with All-selected matches all tag values
    [PSCustomObject]@{
        name=$name; type='query'; label=$label
        datasource=$ds; definition=$q; query=$q
        hide=0; includeAll=$includeAll; allValue=$(if($includeAll){'.+'}else{$null}); multi=$multi
        refresh=1; sort=1; skipUrlSync=$false
        current=@{text=$(if($includeAll){'All'}else{''}); value=$(if($includeAll){@('$__all')}else{''})}
        options=@(); regex=''
    }
}

$wanVar = (TagValuesVar 'WAN' 'Interface' 'interface' 'net' 'r.host =~ /${Host:regex}/ and r.interface != "all" and r.interface != "lo0"' $true $true)

$j.templating.list = @(
    (TagValuesVar 'Host' 'Host' 'host' 'pf' '' $false $false),
    (TagValuesVar 'Disk' 'Disk' 'device' 'disk' 'r.host =~ /${Host:regex}/' $true $true),
    $wanVar,
    (TagValuesVar 'CPU' 'CPU' 'cpu' 'cpu' 'r.host =~ /${Host:regex}/ and r.cpu != "cpu-total"' $true $true)
)

# --- Panel query rewrites ---
function Set-Target($panel, $flux, $refId='A') {
    $panel.targets = @([PSCustomObject]@{
        refId = $refId
        datasource = $ds
        query = $flux
    })
}
function Set-Targets($panel, $list) {
    $panel.targets = @($list | ForEach-Object {
        [PSCustomObject]@{ refId=$_.refId; datasource=$ds; query=$_.flux }
    })
}

function Set-Unit($panel, $unit, $min=$null, $max=$null, $decimals=$null) {
    if (-not $panel.fieldConfig) { $panel | Add-Member -NotePropertyName fieldConfig -NotePropertyValue ([PSCustomObject]@{ defaults=[PSCustomObject]@{}; overrides=@() }) -Force }
    if (-not $panel.fieldConfig.defaults) { $panel.fieldConfig | Add-Member -NotePropertyName defaults -NotePropertyValue ([PSCustomObject]@{}) -Force }
    $panel.fieldConfig.defaults | Add-Member -NotePropertyName unit -NotePropertyValue $unit -Force
    if ($null -ne $min) { $panel.fieldConfig.defaults | Add-Member -NotePropertyName min -NotePropertyValue $min -Force }
    if ($null -ne $max) { $panel.fieldConfig.defaults | Add-Member -NotePropertyName max -NotePropertyValue $max -Force }
    if ($null -ne $decimals) { $panel.fieldConfig.defaults | Add-Member -NotePropertyName decimals -NotePropertyValue $decimals -Force }
    # Palette color for timeseries
    $panel.fieldConfig.defaults | Add-Member -NotePropertyName color -NotePropertyValue ([PSCustomObject]@{ mode='palette-classic' }) -Force
}

foreach ($p in $j.panels) {
    # Modernize legacy 'graph' panels to 'timeseries' — better Flux rendering
    if ($p.type -eq 'graph') {
        $p.type = 'timeseries'
        foreach ($legacy in 'yaxes','xaxis','legend','lines','bars','fill','linewidth','nullPointMode','pointradius','renderer','seriesOverrides','stack','steppedLine','thresholds','tooltip') {
            if ($p.PSObject.Properties[$legacy]) { $p.PSObject.Properties.Remove($legacy) }
        }
    }
    # Reset legacy table options that conflict with Flux output (columns, transform, styles)
    if ($p.type -eq 'table') {
        foreach ($legacy in 'columns','styles','transform','transformations','sort','sortBy','pageSize','showHeader','filterable','scroll','fontSize') {
            if ($p.PSObject.Properties[$legacy]) { $p.PSObject.Properties.Remove($legacy) }
        }
        # Reset fieldConfig so Grafana auto-builds from Flux columns
        $p | Add-Member -NotePropertyName fieldConfig -NotePropertyValue ([PSCustomObject]@{
            defaults=[PSCustomObject]@{ custom=[PSCustomObject]@{ align='auto'; displayMode='auto' } }
            overrides=@()
        }) -Force
        $p | Add-Member -NotePropertyName options -NotePropertyValue ([PSCustomObject]@{
            showHeader=$true; cellHeight='sm'
        }) -Force
    }
    switch ($p.id) {
        49 {  # Active Users (stat)
            if ($p.type -eq 'singlestat') { $p.type = 'stat' }
            Set-Target $p @'
from(bucket: "pfsense")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "system" and r._field == "n_users" and r.host =~ /${Host:regex}/)
  |> aggregateWindow(every: v.windowPeriod, fn: last, createEmpty: false)
  |> yield(name: "last")
'@
        }
        8 {  # CPU Total (gauge): 100 - usage_idle of cpu-total
            Set-Target $p @'
from(bucket: "pfsense")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "cpu" and r.cpu == "cpu-total" and r._field == "usage_idle" and r.host =~ /${Host:regex}/)
  |> mean()
  |> map(fn: (r) => ({ r with _value: 100.0 - r._value }))
'@
            Set-Unit $p 'percent' 0 100 1
        }
        6 {  # CPU per-core: 100 - usage_idle by cpu
            Set-Target $p @'
from(bucket: "pfsense")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "cpu" and r._field == "usage_idle" and r.cpu =~ /${CPU:regex}/ and r.host =~ /${Host:regex}/)
  |> map(fn: (r) => ({ r with _value: 100.0 - r._value }))
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
  |> group(columns: ["cpu"])
'@
            Set-Unit $p 'percent' $null $null 1
        }
        219 {  # Process Information (table) — pivot rows to columns via transformation
            Set-Target $p @'
from(bucket: "pfsense")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "processes" and r.host =~ /${Host:regex}/)
  |> last()
  |> keep(columns: ["_field","_value"])
  |> rename(columns: {_field: "state", _value: "count"})
  |> group()
'@
            $p | Add-Member -NotePropertyName transformations -NotePropertyValue @(
                [PSCustomObject]@{
                    id='rowsToFields'
                    options=[PSCustomObject]@{
                        mappings=@(
                            @{ fieldName='state'; handlerKey='field.name' }
                            @{ fieldName='count'; handlerKey='field.value' }
                        )
                    }
                }
            ) -Force
        }
        18 {  # Load (load1, load5, load15)
            Set-Target $p @'
from(bucket: "pfsense")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "system" and (r._field == "load1" or r._field == "load5" or r._field == "load15") and r.host =~ /${Host:regex}/)
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
'@
            Set-Unit $p 'short' 0 $null 2
        }
        45 {  # Uptime
            if ($p.type -eq 'singlestat') { $p.type = 'stat' }
            Set-Target $p @'
from(bucket: "pfsense")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "system" and r._field == "uptime" and r.host =~ /${Host:regex}/)
  |> aggregateWindow(every: v.windowPeriod, fn: last, createEmpty: false)
  |> yield(name: "last")
'@
            Set-Unit $p 's' 0 $null 0
        }
        220 {  # PF Information (table) — pivot rows to columns
            Set-Target $p @'
from(bucket: "pfsense")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "pf" and r.host =~ /${Host:regex}/)
  |> last()
  |> keep(columns: ["_field","_value"])
  |> rename(columns: {_field: "counter", _value: "value"})
  |> group()
'@
            $p | Add-Member -NotePropertyName transformations -NotePropertyValue @(
                [PSCustomObject]@{
                    id='rowsToFields'
                    options=[PSCustomObject]@{
                        mappings=@(
                            @{ fieldName='counter'; handlerKey='field.name' }
                            @{ fieldName='value'; handlerKey='field.value' }
                        )
                    }
                }
            ) -Force
        }
        223 {  # Disk Utilization (used_percent by device)
            Set-Target $p @'
from(bucket: "pfsense")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "disk" and r._field == "used_percent" and r.device =~ /${Disk:regex}/ and r.host =~ /${Host:regex}/)
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
'@
            Set-Unit $p 'percent' $null $null 1
        }
        17 {  # Ram (mem + swap)
            Set-Targets $p @(
                @{refId='A'; flux=@'
from(bucket: "pfsense")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "mem" and (r._field == "used" or r._field == "available" or r._field == "free" or r._field == "buffered" or r._field == "cached") and r.host =~ /${Host:regex}/)
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
'@},
                @{refId='B'; flux=@'
from(bucket: "pfsense")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "swap" and (r._field == "used" or r._field == "free") and r.host =~ /${Host:regex}/)
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
  |> map(fn: (r) => ({ r with _field: "swap_" + r._field }))
'@}
            )
            Set-Unit $p 'bytes' 0 $null $null
        }
        103 {  # Temperature Sensors (removed earlier — kept here as no-op)
            Set-Target $p @'
from(bucket: "pfsense")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "temperature" and r._field == "temp" and r.sensor =~ /${Sensor:regex}/ and r.host =~ /${Host:regex}/)
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
  |> group(columns: ["sensor"])
'@
        }
        4 {  # Gateway RTT
            Set-Target $p @'
from(bucket: "pfsense")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "gateways" and r._field == "delay" and r.gateway_name =~ /${Gateway:regex}/ and r.host =~ /${Host:regex}/)
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
  |> group(columns: ["gateway_name"])
'@
            Set-Unit $p 'ms' 0 $null 1
        }
        487 {  # Gateway Loss
            Set-Target $p @'
from(bucket: "pfsense")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "gateways" and r._field == "loss" and r.gateway_name =~ /${Gateway:regex}/ and r.host =~ /${Host:regex}/)
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
  |> group(columns: ["gateway_name"])
'@
            Set-Unit $p 'percent' 0 100 1
        }
        194 {  # Interface summary (all)
            Set-Target $p @'
from(bucket: "pfsense")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "net" and r.host =~ /${Host:regex}/ and r.interface != "all")
  |> filter(fn: (r) => r._field == "bytes_recv" or r._field == "bytes_sent" or r._field == "packets_recv" or r._field == "packets_sent" or r._field == "drop_in" or r._field == "drop_out" or r._field == "err_in" or r._field == "err_out")
  |> last()
  |> keep(columns: ["interface","_field","_value"])
  |> group()
  |> pivot(rowKey: ["interface"], columnKey: ["_field"], valueColumn: "_value")
'@
        }
        603 {  # Interface summary (WAN-filtered)
            Set-Target $p @'
from(bucket: "pfsense")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "net" and r.interface =~ /${WAN:regex}/ and r.host =~ /${Host:regex}/)
  |> filter(fn: (r) => r._field == "bytes_recv" or r._field == "bytes_sent" or r._field == "packets_recv" or r._field == "packets_sent" or r._field == "drop_in" or r._field == "drop_out" or r._field == "err_in" or r._field == "err_out")
  |> last()
  |> keep(columns: ["interface","_field","_value"])
  |> group()
  |> pivot(rowKey: ["interface"], columnKey: ["_field"], valueColumn: "_value")
'@
        }
        2 {  # WAN Traffic Bytes/sec
            Set-Targets $p @(
                @{refId='A'; flux=@'
from(bucket: "pfsense")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "net" and r._field == "bytes_recv" and r.interface =~ /${WAN:regex}/ and r.host =~ /${Host:regex}/)
  |> derivative(unit: 1s, nonNegative: true)
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
  |> set(key: "_field", value: "rx_bps")
  |> group(columns: ["interface","_field"])
'@},
                @{refId='B'; flux=@'
from(bucket: "pfsense")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "net" and r._field == "bytes_sent" and r.interface =~ /${WAN:regex}/ and r.host =~ /${Host:regex}/)
  |> derivative(unit: 1s, nonNegative: true)
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
  |> set(key: "_field", value: "tx_bps")
  |> group(columns: ["interface","_field"])
'@}
            )
            Set-Unit $p 'Bps' 0 $null $null
        }
        247 {  # WAN Traffic Bits/sec (stat) — rx + tx combined as bits
            Set-Target $p @'
from(bucket: "pfsense")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "net" and (r._field == "bytes_recv" or r._field == "bytes_sent") and r.interface =~ /${WAN:regex}/ and r.host =~ /${Host:regex}/)
  |> derivative(unit: 1s, nonNegative: true)
  |> map(fn: (r) => ({ r with _value: r._value * 8.0 }))
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
  |> group(columns: ["_field"])
'@
            Set-Unit $p 'bps' 0 $null $null
        }
        296 {  # WAN $WAN (stat) — totals
            Set-Target $p @'
from(bucket: "pfsense")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "net" and (r._field == "bytes_recv" or r._field == "bytes_sent") and r.interface =~ /${WAN:regex}/ and r.host =~ /${Host:regex}/)
  |> last()
  |> group(columns: ["_field"])
'@
            Set-Unit $p 'bytes' 0 $null $null
        }
        322 {  # WAN Throughput (packets/sec)
            Set-Targets $p @(
                @{refId='A'; flux=@'
from(bucket: "pfsense")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "net" and r._field == "packets_recv" and r.interface =~ /${WAN:regex}/ and r.host =~ /${Host:regex}/)
  |> derivative(unit: 1s, nonNegative: true)
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
  |> set(key: "_field", value: "rx_pps")
  |> group(columns: ["_field"])
'@},
                @{refId='B'; flux=@'
from(bucket: "pfsense")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "net" and r._field == "packets_sent" and r.interface =~ /${WAN:regex}/ and r.host =~ /${Host:regex}/)
  |> derivative(unit: 1s, nonNegative: true)
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
  |> set(key: "_field", value: "tx_pps")
  |> group(columns: ["_field"])
'@}
            )
            Set-Unit $p 'pps' 0 $null $null
        }
    }
    if ($p.datasource -and $p.type -ne 'row') {
        $p.datasource = $ds
    }
    # Rename row titles + interface-specific titles
    if ($p.id -eq 143) { $p.title = 'Interfaces' }
    if ($p.id -eq 14)  { $p.title = 'Selected Interfaces - $WAN' }
    if ($p.id -eq 2)   { $p.title = 'Traffic Bytes/sec - $WAN' }
    if ($p.id -eq 247) { $p.title = 'Traffic Bits/sec - $WAN' }
    if ($p.id -eq 296) { $p.title = 'Totals - $WAN' }
    if ($p.id -eq 322) { $p.title = 'Throughput - $WAN' }
}

# Reset full grid layout (24-col)
$layout = @{
    16  = @{ x=0;  y=0;  w=24; h=1 }   # Hardware row
    49  = @{ x=0;  y=1;  w=3;  h=3 }   # Active Users
    45  = @{ x=0;  y=4;  w=3;  h=3 }   # Uptime
    8   = @{ x=3;  y=1;  w=3;  h=6 }   # CPU Total
    6   = @{ x=6;  y=1;  w=9;  h=6 }   # CPU
    18  = @{ x=15; y=1;  w=9;  h=6 }   # Load
    219 = @{ x=0;  y=7;  w=24; h=4 }   # Process Info — FULL ROW (1 row of data)
    220 = @{ x=0;  y=11; w=24; h=5 }   # PF Info — FULL ROW (1 row of data, more columns)
    223 = @{ x=0;  y=16; w=12; h=6 }   # Disk Util
    17  = @{ x=12; y=16; w=12; h=6 }   # Ram
    143 = @{ x=0;  y=22; w=24; h=1 }   # Interfaces row label
    194 = @{ x=0;  y=23; w=24; h=10 }  # Interface summary (all)
    14  = @{ x=0;  y=33; w=24; h=1 }   # Selected interfaces row
    603 = @{ x=0;  y=34; w=24; h=6 }   # Interface summary (selected)
    2   = @{ x=0;  y=40; w=12; h=8 }   # Traffic Bytes
    247 = @{ x=12; y=40; w=4;  h=4 }   # Traffic Bits
    296 = @{ x=12; y=44; w=4;  h=4 }   # Totals
    322 = @{ x=16; y=40; w=8;  h=8 }   # Throughput
}
foreach ($p in $j.panels) {
    if ($layout.ContainsKey($p.id)) {
        $p.gridPos = $layout[$p.id]
    }
}

$j.title = 'pfSense (Flux)'
$j.uid = 'pfsense-flux'
$j.tags = @('pfsense','flux')

$out = $j | ConvertTo-Json -Depth 100
$out = $out -replace '\$\{DS_[^}]*\}', $dsUid
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($path, $out, $utf8NoBom)
"WROTE: $((Get-Item $path).Length) bytes  first3=$(((Get-Content $path -Encoding Byte -TotalCount 3) | ForEach-Object {$_.ToString('X2')}) -join ' ')"
"Panels remaining: $($j.panels.Count)"
