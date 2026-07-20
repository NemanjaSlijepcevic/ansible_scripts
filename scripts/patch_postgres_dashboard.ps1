$path = "C:\Users\nas\Desktop\Projekti\GIT\ansible_scripts\update\roles\grafana\files\postgres-flux.json"
$j = Get-Content $path -Raw | ConvertFrom-Json

foreach ($k in '__inputs','__elements','__requires') {
    if ($j.PSObject.Properties[$k]) { $j.PSObject.Properties.Remove($k) }
}

$hostVar = [PSCustomObject]@{
    name='host'; type='custom'; label='Host'
    query='postgres,nas,server,monitor'
    current=@{text='postgres'; value='postgres'; selected=$true}
    options=@(
        @{text='postgres'; value='postgres'; selected=$true}
        @{text='nas'; value='nas'; selected=$false}
        @{text='server'; value='server'; selected=$false}
        @{text='monitor'; value='monitor'; selected=$false}
    )
    hide=0; includeAll=$false; multi=$false; skipUrlSync=$false
}

$dbVar = [PSCustomObject]@{
    name='db'; type='query'; label='Database'
    datasource=@{type='influxdb'; uid='__INFLUXDB_UID__'}
    definition = @'
import "influxdata/influxdb/schema"
schema.tagValues(bucket: "telegraf-${host}", tag: "db", predicate: (r) => r._measurement == "postgresql")
'@
    query = @'
import "influxdata/influxdb/schema"
schema.tagValues(bucket: "telegraf-${host}", tag: "db", predicate: (r) => r._measurement == "postgresql")
'@
    hide=0; includeAll=$true; allValue=''; multi=$true; refresh=1; sort=1; skipUrlSync=$false
    current=@{text='All'; value=@('$__all')}
    options=@()
    regex=''
}

$j.templating.list = @($hostVar, $dbVar)

function Set-FluxTarget($panel, $targets) {
    $panel.targets = @($targets | ForEach-Object {
        [PSCustomObject]@{
            refId = $_.refId
            datasource = @{ type='influxdb'; uid='__INFLUXDB_UID__' }
            query = $_.flux
        }
    })
}

# Rate query template — derivative of counter field, optionally aliased
function Rate-Flux($field, $alias) {
@"
from(bucket: "telegraf-`${host}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "postgresql" and r._field == "$field")
  |> filter(fn: (r) => r.db =~ /`${db:regex}/)
  |> derivative(unit: 1s, nonNegative: true)
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
  |> group(columns: ["db"])
  |> set(key: "_field", value: "$alias")
"@
}

# Plain value (gauge-like)
function Value-Flux($field, $alias) {
@"
from(bucket: "telegraf-`${host}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "postgresql" and r._field == "$field")
  |> filter(fn: (r) => r.db =~ /`${db:regex}/)
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
  |> group(columns: ["db"])
  |> set(key: "_field", value: "$alias")
"@
}

foreach ($panel in $j.panels) {
    switch ($panel.id) {
        1 {  # Rows
            $panel.title = 'Rows (rate/sec by db)'
            Set-FluxTarget $panel @(
                @{refId='A'; flux=(Rate-Flux 'tup_fetched' 'fetched')},
                @{refId='B'; flux=(Rate-Flux 'tup_returned' 'returned')},
                @{refId='C'; flux=(Rate-Flux 'tup_inserted' 'inserted')},
                @{refId='D'; flux=(Rate-Flux 'tup_updated' 'updated')},
                @{refId='E'; flux=(Rate-Flux 'tup_deleted' 'deleted')}
            )
        }
        11 {  # QPS — transactions/sec
            $panel.title = 'Transactions/sec'
            if ($panel.type -eq 'singlestat') { $panel.type = 'stat' }
            Set-FluxTarget $panel @(
                @{refId='A'; flux=@"
from(bucket: "telegraf-`${host}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "postgresql" and (r._field == "xact_commit" or r._field == "xact_rollback"))
  |> filter(fn: (r) => r.db =~ /`${db:regex}/)
  |> derivative(unit: 1s, nonNegative: true)
  |> group()
  |> sum()
"@}
            )
        }
        2 {  # Buffers
            $panel.title = 'Buffer hits vs disk reads (rate/sec)'
            Set-FluxTarget $panel @(
                @{refId='A'; flux=(Rate-Flux 'blks_hit' 'cache_hit')},
                @{refId='B'; flux=(Rate-Flux 'blks_read' 'disk_read')}
            )
        }
        3 {  # Conflicts/Deadlocks
            $panel.title = 'Conflicts / Deadlocks (rate/sec)'
            Set-FluxTarget $panel @(
                @{refId='A'; flux=(Rate-Flux 'conflicts' 'conflicts')},
                @{refId='B'; flux=(Rate-Flux 'deadlocks' 'deadlocks')}
            )
        }
        12 {  # Cache hit ratio
            $panel.title = 'Cache hit ratio (%)'
            Set-FluxTarget $panel @(
                @{refId='A'; flux=@"
hit = from(bucket: "telegraf-`${host}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "postgresql" and r._field == "blks_hit")
  |> filter(fn: (r) => r.db =~ /`${db:regex}/)
  |> derivative(unit: 1s, nonNegative: true)
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
  |> group(columns: ["db"])
read = from(bucket: "telegraf-`${host}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "postgresql" and r._field == "blks_read")
  |> filter(fn: (r) => r.db =~ /`${db:regex}/)
  |> derivative(unit: 1s, nonNegative: true)
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
  |> group(columns: ["db"])
join(tables: {hit: hit, read: read}, on: ["_time","db"])
  |> map(fn: (r) => ({ _time: r._time, db: r.db, _value: if (r._value_hit + r._value_read) == 0.0 then 0.0 else 100.0 * r._value_hit / (r._value_hit + r._value_read) }))
  |> group(columns: ["db"])
"@}
            )
        }
        13 {  # Active connections
            $panel.title = 'Active connections (numbackends)'
            Set-FluxTarget $panel @(
                @{refId='A'; flux=(Value-Flux 'numbackends' 'connections')}
            )
        }
    }
    # Reset panel-level datasource
    if ($panel.datasource) {
        $panel.datasource = @{ type='influxdb'; uid='__INFLUXDB_UID__' }
    }
}

$j.title = 'PostgreSQL (Flux)'
$j.uid = 'postgres-flux-perhost'

$out = $j | ConvertTo-Json -Depth 100
$out = $out -replace '\$\{DS_[^}]*\}', '__INFLUXDB_UID__'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($path, $out, $utf8NoBom)
"WROTE: $((Get-Item $path).Length) bytes  first3=$(((Get-Content $path -Encoding Byte -TotalCount 3) | ForEach-Object {$_.ToString('X2')}) -join ' ')"
