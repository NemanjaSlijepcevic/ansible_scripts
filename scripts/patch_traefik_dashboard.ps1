$path = "C:\Users\nas\Desktop\Projekti\GIT\ansible_scripts\update\roles\grafana\files\traefik-flux.json"
$j = Get-Content $path -Raw | ConvertFrom-Json

# Strip import-time metadata
foreach ($k in '__inputs','__elements','__requires') {
    if ($j.PSObject.Properties[$k]) { $j.PSObject.Properties.Remove($k) }
}

# Build new templating list
$samplingVar = [PSCustomObject]@{
    name = 'sampling'; type = 'custom'; label = 'Sampling'
    query = '1m,10m,60m'; current = @{ text='1m'; value='1m'; selected=$true }
    options = @(
        @{text='1m'; value='1m'; selected=$true}
        @{text='10m'; value='10m'; selected=$false}
        @{text='60m'; value='60m'; selected=$false}
    )
    hide=0; includeAll=$false; multi=$false; skipUrlSync=$false
}

$hostVar = [PSCustomObject]@{
    name = 'host'; type = 'custom'; label = 'Host'
    query = 'nas,server,monitor,netboot,postgres'
    current = @{ text='monitor'; value='monitor'; selected=$true }
    options = @(
        @{text='nas'; value='nas'; selected=$false}
        @{text='server'; value='server'; selected=$false}
        @{text='monitor'; value='monitor'; selected=$true}
        @{text='netboot'; value='netboot'; selected=$false}
        @{text='postgres'; value='postgres'; selected=$false}
    )
    hide=0; includeAll=$false; multi=$false; skipUrlSync=$false
}

$serviceVar = [PSCustomObject]@{
    name = 'service'; type = 'query'; label = 'Service'
    datasource = @{ type='influxdb'; uid='__INFLUXDB_UID__' }
    definition = @'
import "influxdata/influxdb/schema"
schema.tagValues(bucket: "traefik-${host}", tag: "service", predicate: (r) => r._measurement == "traefik.service.requests.total")
'@
    query = @'
import "influxdata/influxdb/schema"
schema.tagValues(bucket: "traefik-${host}", tag: "service", predicate: (r) => r._measurement == "traefik.service.requests.total")
'@
    hide=0; includeAll=$true; allValue=''; multi=$true; refresh=1; sort=1; skipUrlSync=$false
    current = @{ text='All'; value=@('$__all') }
    options = @()
    regex=''
}

$j.templating.list = @($hostVar, $samplingVar, $serviceVar)

function Set-FluxTarget($panel, $flux) {
    $panel.targets = @(
        [PSCustomObject]@{
            refId = 'A'
            datasource = @{ type='influxdb'; uid='__INFLUXDB_UID__' }
            query = $flux
        }
    )
}

foreach ($panel in $j.panels) {
    switch ($panel.id) {
        14 {  # Total request (stat)
            Set-FluxTarget $panel @'
from(bucket: "traefik-${host}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "traefik.router.requests.total" and r._field == "count")
  |> group()
  |> sum()
'@
            $panel.gridPos = @{ x=0; y=0; w=4; h=9 }
        }
        12 {  # Access by service
            $panel.title = 'Requests per service'
            $panel.gridPos = @{ x=4; y=0; w=20; h=9 }
            Set-FluxTarget $panel @'
from(bucket: "traefik-${host}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "traefik.service.requests.total" and r._field == "count")
  |> filter(fn: (r) => r.service =~ /${service:regex}/)
  |> derivative(unit: 1s, nonNegative: true)
  |> aggregateWindow(every: ${sampling}, fn: sum, createEmpty: false)
  |> group(columns: ["service"])
'@
        }
        10 {  # Average response time
            Set-FluxTarget $panel @'
from(bucket: "traefik-${host}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "traefik.service.request.duration" and r._field == "p99")
  |> filter(fn: (r) => r.service =~ /${service:regex}/)
  |> aggregateWindow(every: ${sampling}, fn: mean, createEmpty: false)
  |> group(columns: ["service"])
'@
        }
        2 {  # Status code count
            Set-FluxTarget $panel @'
from(bucket: "traefik-${host}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "traefik.router.requests.total" and r._field == "count")
  |> derivative(unit: 1s, nonNegative: true)
  |> aggregateWindow(every: ${sampling}, fn: sum, createEmpty: false)
  |> group(columns: ["code"])
'@
        }
        6 {  # Open connections
            Set-FluxTarget $panel @'
from(bucket: "traefik-${host}")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "traefik.open.connections" and r._field == "value")
  |> aggregateWindow(every: ${sampling}, fn: mean, createEmpty: false)
  |> group(columns: ["entrypoint","protocol","method"])
'@
        }
        4 {  # Log Volume (Loki)
            foreach ($t in $panel.targets) {
                $t.datasource = @{ type='loki'; uid='__LOKI_UID__' }
                $t.expr = '(count_over_time({job="traefik"}[$__interval]))'
            }
        }
        8 {  # Traefik JSON Logs (Loki)
            foreach ($t in $panel.targets) {
                $t.datasource = @{ type='loki'; uid='__LOKI_UID__' }
                $t.expr = '{job="traefik"} | json | line_format "{{.OriginStatus}} | {{.time}} | {{.RequestAddr}} | {{.ClientHost}} | {{.RequestMethod}} {{.RequestPath}} {{.RequestProtocol}} | {{.request_User_Agent}}"'
            }
        }
    }
    # Reset datasource at panel level for influxdb panels
    if ($panel.datasource -and $panel.datasource.type -eq 'influxdb') {
        $panel.datasource = @{ type='influxdb'; uid='__INFLUXDB_UID__' }
    } elseif ($panel.datasource -and $panel.datasource.type -eq 'loki') {
        $panel.datasource = @{ type='loki'; uid='__LOKI_UID__' }
    }
}

# Title bump
$j.title = 'Traefik (Flux per-host)'
$j.uid = 'traefik-flux-perhost'

$out = $j | ConvertTo-Json -Depth 100
# Sanity: ensure no leftover original DS placeholders
$out = $out -replace '\$\{DS_INFLUXDB-TRAEFIK\}', '__INFLUXDB_UID__'
$out = $out -replace '\$\{DS_LOKI\}', '__LOKI_UID__'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($path, $out, $utf8NoBom)
"WROTE: $((Get-Item $path).Length) bytes"
