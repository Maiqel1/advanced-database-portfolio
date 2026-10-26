$ErrorActionPreference = 'Continue'
$network = 'advanced-database-portfolio_default'
$members = 'hospital-mongo', 'hospital-mongo-2', 'hospital-mongo-3'

function Step([string]$container, [string]$step, [string]$old = '', [string]$label = '') {
    docker exec -e "STEP=$step" -e "OLD=$old" -e "LABEL=$label" $container mongosh --nodb --quiet --file /portfolio/portfolio-5-distributed-cloud/steps.js 2>&1 |
        ForEach-Object { "$_" }
}

function Get-Primary {
    $via = docker ps --format '{{.Names}}' | Where-Object { $members -contains $_ } | Select-Object -First 1
    (Step $via 'primary' | Select-Object -Last 1).Trim()
}

function Wait-Up([string]$container) {
    for ($i = 0; $i -lt 60; $i++) {
        docker exec $container mongosh --quiet --eval 'db.runCommand({ ping: 1 }).ok' *> $null
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Seconds 1
    }
}

function Title([string]$text) {
    ''
    '#' * 70
    $text
    '#' * 70
}

Title 'PART 1: REPLICATION'
Step 'hospital-mongo-2' 'status'
''
Step 'hospital-mongo-2' 'replication'

Title 'PART 2: READING FROM A SECONDARY CAN GIVE AN OUT-OF-DATE ANSWER'
Step 'hospital-mongo-2' 'staleread'

Title 'PART 3: AUTOMATIC FAILOVER WHEN THE PRIMARY CRASHES'
$primary = Get-Primary
$survivor = $members | Where-Object { $_ -ne $primary } | Select-Object -First 1
docker update --restart=no $primary | Out-Null
"Killing $primary, the primary, with docker kill (a crash, not a clean shutdown)"
$clock = [Diagnostics.Stopwatch]::StartNew()
docker kill $primary | Out-Null
Step $survivor 'waitprimary' "$($primary):27017" 'written-after-crash'
'Time from the kill until a write succeeded again: {0:N1} s' -f $clock.Elapsed.TotalSeconds
''
"Restarting $primary"
docker start $primary | Out-Null
docker update --restart=unless-stopped $primary | Out-Null
Wait-Up $primary
Start-Sleep -Seconds 15
Step $primary 'status'

Title 'PART 4: LOSING THE MAJORITY'
$primary = Get-Primary
$others = $members | Where-Object { $_ -ne $primary }
"Stopping both secondaries: $($others -join ' and '). Only $primary is left."
docker stop $others | Out-Null
Step $primary 'stepdown'
''
'Starting the two secondaries again'
docker start $others | Out-Null
foreach ($m in $others) { Wait-Up $m }
Step $primary 'waitprimary' '' 'written-after-majority-returned'

Title 'PART 5: A NETWORK PARTITION AND WHY w: majority MATTERS'
Start-Sleep -Seconds 10
$primary = Get-Primary
$majority = $members | Where-Object { $_ -ne $primary } | Select-Object -First 1
foreach ($m in $members) { docker exec $m rm -rf /data/db/rollback }
"Disconnecting $primary, the primary, from the network"
docker network disconnect $network $primary
Step $primary 'partitionold'
''
Step $majority 'partitionmajority' "$($primary):27017"
''
"Reconnecting $primary"
docker network connect $network $primary
Step $primary 'partitionheal'
''
"Rollback files kept by $primary (the writes it had to undo):"
$files = docker exec $primary sh -c 'find /data/db/rollback -name ''*.bson'' 2>/dev/null'
foreach ($f in $files) {
    "  $f"
    docker exec $primary bsondump --quiet $f 2>&1 | ForEach-Object { "    $_" }
}

Title 'CLEAN-UP'
Start-Sleep -Seconds 10
Step 'hospital-mongo-2' 'cleanup'
