$ErrorActionPreference = 'Continue'
$start = Get-Date
$compose = Join-Path $PSScriptRoot '..\docker-compose.yml'

function Wait-ForDatabases {
    for ($i = 0; $i -lt 60; $i++) {
        docker exec hospital-postgres pg_isready -U hospital_admin -d hospital *> $null
        $pg = $LASTEXITCODE
        docker exec hospital-mongo mongosh --quiet --eval 'db.runCommand({ ping: 1 }).ok' *> $null
        if ($pg -eq 0 -and $LASTEXITCODE -eq 0) { return }
        Start-Sleep -Seconds 2
    }
    throw 'The databases did not start within two minutes'
}

Write-Output '=== 1. Starting PostgreSQL and MongoDB'
docker compose -f $compose up -d 2>&1 | ForEach-Object { "$_" }
Wait-ForDatabases

Write-Output ''
Write-Output '=== 2. Exporting September 2026 from PostgreSQL'
docker exec -u root hospital-postgres chmod 1777 /exchange
docker exec hospital-postgres psql -U hospital_admin -d hospital -X -f /portfolio/portfolio-4-nosql/export.sql 2>&1 | ForEach-Object { "$_" }

Write-Output ''
Write-Output '=== 3. Setting up MongoDB: replica set, collections and validators'
docker exec hospital-mongo mongosh --quiet --file /portfolio/portfolio-4-nosql/setup.js 2>&1 | ForEach-Object { "$_" }

Write-Output ''
Write-Output '=== 4. Importing into MongoDB (every document is checked against its validator)'
foreach ($collection in 'branches', 'drugs', 'labTests', 'branchStock', 'patients', 'visits') {
    docker exec hospital-mongo mongoimport --db tomiwa --collection $collection --file "/exchange/$collection.json" --numInsertionWorkers 4 --stopOnError 2>&1 |
        ForEach-Object { "$_" } |
        Select-String -Pattern 'imported|failed|error' |
        ForEach-Object { "  {0,-12} {1}" -f $collection, ($_.Line -replace '^\S+\s+', '') }
    if ($LASTEXITCODE -ne 0) { throw "Importing $collection failed" }
}

Write-Output ''
'Finished in {0:N0} seconds' -f ((Get-Date) - $start).TotalSeconds
