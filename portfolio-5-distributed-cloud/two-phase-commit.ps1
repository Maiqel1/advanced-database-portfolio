$ErrorActionPreference = 'Continue'
$drug = 'Amoxicillin 500 mg capsule'

function Site([string]$database, [string[]]$statements) {
    $arguments = @()
    foreach ($s in $statements) { $arguments += '-c'; $arguments += $s }
    docker exec hospital-postgres psql -U hospital_admin -d $database -X -e @arguments 2>&1 | ForEach-Object { "    $_" }
}

function Stock {
    foreach ($site in 'site_ikeja', 'site_ilorin') {
        docker exec hospital-postgres psql -U hospital_admin -d $site -X -tA -c "SELECT current_database() || ': ' || quantity FROM stock" 2>&1 |
            ForEach-Object { "  stock at $_" }
    }
}

function InDoubt {
    '  Prepared transactions waiting for a decision:'
    docker exec hospital-postgres psql -U hospital_admin -d hospital -X -tA -c "SELECT '    ' || gid || ' in ' || database FROM pg_prepared_xacts ORDER BY database" 2>&1 |
        ForEach-Object { "$_" }
}

function Title([string]$text) {
    ''
    '#' * 70
    $text
    '#' * 70
}

function Wait-ForPostgres {
    for ($i = 0; $i -lt 60; $i++) {
        docker exec hospital-postgres pg_isready -U hospital_admin -d hospital *> $null
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Seconds 1
    }
}

Title 'SETUP: two branch databases, each with its own amoxicillin stock'
docker exec hospital-postgres psql -U hospital_admin -d hospital -X -tA -c "SELECT database || ' ' || gid FROM pg_prepared_xacts" 2>&1 |
    ForEach-Object {
        $parts = "$_".Split(' ')
        if ($parts.Length -eq 2) {
            docker exec hospital-postgres psql -U hospital_admin -d $parts[0] -X -q -c "ROLLBACK PREPARED '$($parts[1])'" | Out-Null
        }
    }
foreach ($site in 'site_ikeja', 'site_ilorin') {
    docker exec hospital-postgres psql -U hospital_admin -d hospital -X -q -c "DROP DATABASE IF EXISTS $site WITH (FORCE)" 2>&1 | Out-Null
    docker exec hospital-postgres psql -U hospital_admin -d hospital -X -q -c "CREATE DATABASE $site" | Out-Null
    docker exec hospital-postgres psql -U hospital_admin -d $site -X -q -c "CREATE TABLE stock (drug text PRIMARY KEY, quantity integer NOT NULL CHECK (quantity >= 0))" | Out-Null
}
docker exec hospital-postgres psql -U hospital_admin -d site_ikeja -X -q -c "INSERT INTO stock VALUES ('$drug', 900)" | Out-Null
docker exec hospital-postgres psql -U hospital_admin -d site_ilorin -X -q -c "INSERT INTO stock VALUES ('$drug', 40)" | Out-Null
Stock

Title 'CASE 1: Ikeja sends 300 to Ilorin, and both sites vote yes'
'Phase 1, prepare: each site does its part and promises it can commit'
'  Ikeja:'
Site 'site_ikeja' @('BEGIN', "UPDATE stock SET quantity = quantity - 300 WHERE drug = '$drug'", "PREPARE TRANSACTION 'transfer-1-ikeja'")
'  Ilorin:'
Site 'site_ilorin' @('BEGIN', "UPDATE stock SET quantity = quantity + 300 WHERE drug = '$drug'", "PREPARE TRANSACTION 'transfer-1-ilorin'")
InDoubt
'Phase 2, commit: both voted yes, so the coordinator tells both to commit'
Site 'site_ikeja' @("COMMIT PREPARED 'transfer-1-ikeja'")
Site 'site_ilorin' @("COMMIT PREPARED 'transfer-1-ilorin'")
Stock

Title 'CASE 2: Ikeja is asked to send 700 but holds only 600, so it votes no'
'  Ilorin prepares first:'
Site 'site_ilorin' @('BEGIN', "UPDATE stock SET quantity = quantity + 700 WHERE drug = '$drug'", "PREPARE TRANSACTION 'transfer-2-ilorin'")
'  Ikeja cannot do its part:'
Site 'site_ikeja' @('BEGIN', "UPDATE stock SET quantity = quantity - 700 WHERE drug = '$drug'", "PREPARE TRANSACTION 'transfer-2-ikeja'")
InDoubt
'One site voted no, so the coordinator tells Ilorin to roll back its prepared part:'
Site 'site_ilorin' @("ROLLBACK PREPARED 'transfer-2-ilorin'")
Stock

Title 'CASE 3: the server crashes after both sites have prepared'
Site 'site_ikeja' @('BEGIN', "UPDATE stock SET quantity = quantity - 100 WHERE drug = '$drug'", "PREPARE TRANSACTION 'transfer-3-ikeja'")
Site 'site_ilorin' @('BEGIN', "UPDATE stock SET quantity = quantity + 100 WHERE drug = '$drug'", "PREPARE TRANSACTION 'transfer-3-ilorin'")
'Both sites have voted yes. Before the coordinator sends its decision, PostgreSQL is killed:'
docker update --restart=no hospital-postgres | Out-Null
docker kill hospital-postgres | Out-Null
docker start hospital-postgres | Out-Null
docker update --restart=unless-stopped hospital-postgres | Out-Null
Wait-ForPostgres
'After the restart, the prepared transactions are still there, waiting:'
InDoubt
Stock
'They still hold their row locks, so Ikeja''s pharmacy cannot dispense amoxicillin until the decision arrives:'
Site 'site_ikeja' @("SET lock_timeout = '3s'", "UPDATE stock SET quantity = quantity - 1 WHERE drug = '$drug'")
'The coordinator recovers, reads its log showing both sites voted yes, and finishes the commit:'
Site 'site_ikeja' @("COMMIT PREPARED 'transfer-3-ikeja'")
Site 'site_ilorin' @("COMMIT PREPARED 'transfer-3-ilorin'")
InDoubt
Stock

Title 'CLEAN-UP'
foreach ($site in 'site_ikeja', 'site_ilorin') {
    docker exec hospital-postgres psql -U hospital_admin -d hospital -X -q -c "DROP DATABASE $site WITH (FORCE)" 2>&1 | Out-Null
}
'Both test databases removed.'
