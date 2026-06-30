const fs = require('fs');
const path = require('path');
const { Pool } = require('pg');
const { spawn } = require('child_process');
const mysql = require('mysql2/promise');

/* ============================================================
   DB CONNECTION
============================================================ */

const pool = new Pool({
  host: process.env.DB_HOST,
  user: process.env.DB_USER,
  password: process.env.DB_PASS,
  database: process.env.DB_NAME,
});

/* ============================================================
   CONFIG
============================================================ */

const TF_BIN = '/usr/local/bin/terraform';
const TF_DIR = '/terraform';

const DEFAULT_BACKEND_IMAGE =
  process.env.DEFAULT_BACKEND_IMAGE ||
  "hakeemraj/kenyaemr-backend:latest";

const DEFAULT_FRONTEND_IMAGE =
  process.env.DEFAULT_FRONTEND_IMAGE ||
  "hakeemraj/kenyaemr-frontend:multi";

/* ============================================================
   MYSQL PROVISIONING
============================================================ */

async function provisionDatabase(tenantId) {

  const db = `openmrs_${tenantId}`;
  const dbUser = `${tenantId}_user`;
  const dbPassword = `${tenantId}_pass`;

  const conn = await mysql.createConnection({
    host: process.env.MYSQL_ADMIN_HOST,
    user: process.env.MYSQL_ADMIN_USER,
    password: process.env.MYSQL_ADMIN_PASSWORD,
    port: process.env.MYSQL_ADMIN_PORT || 3306,
  });

  try {
    console.log(`Provisioning DB for ${tenantId}`);

    await conn.query(
      `CREATE DATABASE IF NOT EXISTS \`${db}\``
    );

    await conn.query(
      `CREATE USER IF NOT EXISTS '${dbUser}'@'%' IDENTIFIED BY ?`,
      [dbPassword]
    );

    await conn.query(
      `GRANT ALL PRIVILEGES ON \`${db}\`.* TO '${dbUser}'@'%'`
    );

    await conn.query(`FLUSH PRIVILEGES`);
  }
  finally {
    await conn.end();
  }
}

async function dropDatabase(tenantId) {

  const db = `openmrs_${tenantId}`;
  const dbUser = `${tenantId}_user`;

  const conn = await mysql.createConnection({
    host: process.env.MYSQL_ADMIN_HOST,
    user: process.env.MYSQL_ADMIN_USER,
    password: process.env.MYSQL_ADMIN_PASSWORD,
    port: process.env.MYSQL_ADMIN_PORT || 3306,
  });

  try {
    console.log(`Dropping DB for ${tenantId}`);

    await conn.query(
      `DROP DATABASE IF EXISTS \`${db}\``
    );

    await conn.query(
      `DROP USER IF EXISTS '${dbUser}'@'%'`
    );

    await conn.query(`FLUSH PRIVILEGES`);
  }
  finally {
    await conn.end();
  }
}

/* ============================================================
   MIGRATION WITH PROGRESS %
============================================================ */
async function runMigration(
  tenantId,
  filePath,
  operationId
) {

  const db = `openmrs_${tenantId}`;
  const dbUser = `${tenantId}_user`;
  const dbPassword = `${tenantId}_pass`;

  if (!filePath) {
    throw new Error("No migration file specified");
  }

  if (!fs.existsSync(filePath)) {
    throw new Error(
      `Migration file not found: ${filePath}`
    );
  }

  console.log(
    `Streaming restore ${filePath}`
  );

  let lastProgress = 0;

  return new Promise((resolve, reject) => {

    const gunzip = spawn(
      "gunzip",
      ["-c", filePath]
    );

    const sanitize = spawn(
      "sed",
      [
        "-e",
        "s/DEFINER[ ]*=[ ]*[^*]*\\*/\\*/g",
        "-e",
        "s/SQL SECURITY DEFINER/SQL SECURITY INVOKER/g"
      ]
    );

    const pv = spawn(
      "pv",
      ["-n"]
    );

    const mysqlProc = spawn(
      "mysql",
      [
        `-h${process.env.MYSQL_ADMIN_HOST}`,
        `-u${dbUser}`,
        `-p${dbPassword}`,
        "--ssl=0",
        "--max_allowed_packet=1G",
        "--connect_timeout=60",
        db
      ]
    );

    gunzip.stdout.pipe(sanitize.stdin);
    sanitize.stdout.pipe(pv.stdin);
    pv.stdout.pipe(mysqlProc.stdin);

    pv.stderr.on(
      "data",
      async (data) => {

        const percent = parseFloat(
          data.toString().trim()
        );

        if (
          !isNaN(percent) &&
          percent - lastProgress >= 1
        ) {

          lastProgress = percent;

          await pool.query(
            `UPDATE tenant_operations
             SET progress=$1,
                 message='restoring database'
             WHERE id=$2`,
            [
              Math.round(percent),
              operationId
            ]
          );
        }
      }
    );

    gunzip.stderr.on(
      "data",
      d => console.error("gunzip:", d.toString())
    );

    sanitize.stderr.on(
      "data",
      d => console.error("sed:", d.toString())
    );

    mysqlProc.stderr.on(
      "data",
      d => console.error("mysql:", d.toString())
    );

    mysqlProc.on(
      "close",
      async code => {

        if (code !== 0) {
          reject(new Error("mysql restore failed"));
          return;
        }

        console.log("Restore completed");

        fs.unlinkSync(filePath);

        await pool.query(
          `UPDATE tenant_operations
           SET progress=100,
               message='finalizing'
           WHERE id=$1`,
          [operationId]
        );

        resolve();
      }
    );
  });
}

/* ============================================================
   UTILITIES
============================================================ */

async function sleep(ms) {
  return new Promise(res => setTimeout(res, ms));
}

function run(cmd, args, cwd) {
  return new Promise((resolve, reject) => {

    const proc = spawn(cmd, args, { cwd });

    let logs = '';

    proc.stdout.on('data', d => logs += d.toString());
    proc.stderr.on('data', d => logs += d.toString());

    proc.on('error', err => reject(`Spawn error: ${err.message}`));

    proc.on('exit', code => resolve({ code, logs }));
  });
}

async function restartBackendDeployment(tenantId) {

  console.log(`Restarting backend for ${tenantId}`);

  await run(
    "kubectl",
    [
      "rollout",
      "restart",
      `deployment/${tenantId}-backend`,
      "-n",
      `kenyaemr-tenant-${tenantId}`
    ]
  );
}

/* ============================================================
   JOB FETCHING
============================================================ */

async function fetchJob() {

  const client = await pool.connect();

  try {
    await client.query('BEGIN');

    const res = await client.query(`
      SELECT id, operation_id
      FROM operation_queue
      WHERE status='QUEUED'
      FOR UPDATE SKIP LOCKED
      LIMIT 1
    `);

    if (res.rowCount === 0) {
      await client.query('ROLLBACK');
      return null;
    }

    const row = res.rows[0];

    await client.query(
      `UPDATE operation_queue
       SET status='RUNNING',
           locked_at=now()
       WHERE id=$1`,
      [row.id]
    );

    await client.query('COMMIT');

    return row.operation_id;
  }
  catch (e) {
    await client.query('ROLLBACK');
    console.error('fetchJob error:', e);
    return null;
  }
  finally {
    client.release();
  }
}

async function getOperation(operationId) {

  const res = await pool.query(
    `SELECT * FROM tenant_operations WHERE id=$1`,
    [operationId]
  );

  return res.rows[0];
}

/* ============================================================
   TERRAFORM — PER-TENANT, ISOLATED S3 STATE
============================================================ */

const TENANTS_DIR = path.join(TF_DIR, 'tenants');
const TEMPLATE_DIR = path.join(TENANTS_DIR, '_template');

const S3_BUCKET = process.env.TF_STATE_BUCKET || 'kilifi-wal-archive-prod';
const S3_REGION = process.env.TF_STATE_REGION || 'af-south-1';

function tenantDir(tenantId) {
  return path.join(TENANTS_DIR, tenantId);
}

function writeBackendTf(tenantId, dir) {
  const content = `terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
  }

  backend "s3" {
    bucket = "${S3_BUCKET}"
    key    = "terraform/tenants/${tenantId}/terraform.tfstate"
    region = "${S3_REGION}"
  }
}
`;
  fs.writeFileSync(path.join(dir, 'backend.tf'), content);
}

function writeStaticFiles(dir) {
  fs.copyFileSync(
    path.join(TEMPLATE_DIR, 'variables.tf'),
    path.join(dir, 'variables.tf')
  );
  fs.copyFileSync(
    path.join(TEMPLATE_DIR, 'main.tf'),
    path.join(dir, 'main.tf')
  );
}

function tfEscape(value) {
  return String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"');
}

function writeTfvars(row, dir) {

  const tenantId = row.id;

  const vars = {
    tenant_name: tenantId,
    db_schema: `openmrs_${tenantId}`,
    db_host: process.env.MYSQL_ADMIN_HOST,
    db_user: `${tenantId}_user`,
    db_password: `${tenantId}_pass`,
    backend_image: row.backend_image || DEFAULT_BACKEND_IMAGE,
    frontend_image: row.frontend_image || DEFAULT_FRONTEND_IMAGE,
    oidc_realm: tenantId,
    oidc_client_id: `${tenantId}-spa`,
    oidc_issuer: `https://keycloak.kenyahmis.org/realms/${tenantId}`,
  };

  const lines = Object.entries(vars)
    .map(([k, v]) => `${k.padEnd(15)} = "${tfEscape(v)}"`)
    .join('\n');

  fs.writeFileSync(path.join(dir, 'terraform.tfvars'), lines + '\n');
}

/**
 * Writes/refreshes backend.tf, variables.tf, main.tf, terraform.tfvars
 * for a single tenant. Always reflects current DB row state.
 */
async function ensureTenantScaffold(tenantId) {

  const res = await pool.query(
    `SELECT * FROM tenants WHERE id=$1`,
    [tenantId]
  );

  if (res.rowCount === 0) {
    throw new Error(`Tenant ${tenantId} not found in tenants table`);
  }

  const row = res.rows[0];
  const dir = tenantDir(tenantId);

  fs.mkdirSync(dir, { recursive: true });

  writeStaticFiles(dir);
  writeBackendTf(tenantId, dir);
  writeTfvars(row, dir);

  return dir;
}

/**
 * Runs terraform init/plan/[apply|destroy] scoped to exactly one
 * tenant's directory + S3 state key. Never touches any other tenant
 * or the shared mysql/keycloak/hub root state.
 */
async function runTerraformForTenant(tenantId, { destroy = false } = {}) {

  const dir = await ensureTenantScaffold(tenantId);

  let logs = '';

  const init = await run(
    TF_BIN,
    ['init', '-input=false', '-upgrade=false'],
    dir
  );
  logs += init.logs;
  if (init.code !== 0) throw logs;

  if (destroy) {

    const dApply = await run(
      TF_BIN,
      ['destroy', '-auto-approve', '-input=false'],
      dir
    );
    logs += dApply.logs;
    if (dApply.code !== 0) throw logs;

    // remove the local working directory after a clean destroy.
    // state itself lived in S3, so this just clears the local checkout.
    fs.rmSync(dir, { recursive: true, force: true });

    return logs;
  }

  const plan = await run(
    TF_BIN,
    ['plan', '-detailed-exitcode', '-input=false'],
    dir
  );
  logs += plan.logs;
  if (plan.code === 1) throw logs;

  if (plan.code === 2) {

    const apply = await run(
      TF_BIN,
      ['apply', '-auto-approve', '-input=false'],
      dir
    );
    logs += apply.logs;
    if (apply.code !== 0) throw logs;
  }

  return logs;
}

/* ============================================================
   PROCESS JOB
============================================================ */

async function processJob(operationId) {

  let op;

  try {

    op = await getOperation(operationId);

    const action = op.action?.toUpperCase();

    console.log(
      `Processing ${action} for tenant ${op.tenant_id}`
    );

    /* mark operation running */

    await pool.query(
      `UPDATE tenant_operations
       SET status='RUNNING',
           started_at=now()
       WHERE id=$1`,
      [operationId]
    );

    /* prevent concurrent pipelines for same tenant */

    const runningCheck = await pool.query(
      `SELECT 1
       FROM tenant_operations
       WHERE tenant_id=$1
         AND status IN ('RUNNING','MIGRATING')
         AND id<>$2
       LIMIT 1`,
      [op.tenant_id, operationId]
    );

    if (runningCheck.rowCount > 0) {
      throw new Error(
        "Another pipeline is already running for this tenant"
      );
    }

    /* ---------- ENABLE ---------- */

    if (action === 'ENABLE') {

      await pool.query(
        `UPDATE tenants SET enabled=true WHERE id=$1`,
        [op.tenant_id]
      );

      await provisionDatabase(op.tenant_id);

      await runTerraformForTenant(op.tenant_id);
    }

    /* ---------- DISABLE ---------- */

    if (action === 'DISABLE') {

      await pool.query(
        `UPDATE tenants SET enabled=false WHERE id=$1`,
        [op.tenant_id]
      );

      await runTerraformForTenant(op.tenant_id);
    }

    /* ---------- DELETE ---------- */

    if (action === 'DELETE') {

      await pool.query(
        `UPDATE tenants
         SET lifecycle='DELETING',
             enabled=false
         WHERE id=$1`,
        [op.tenant_id]
      );

      await dropDatabase(op.tenant_id);

      await runTerraformForTenant(op.tenant_id, { destroy: true });

      await pool.query(
        `UPDATE tenants SET lifecycle='DELETED' WHERE id=$1`,
        [op.tenant_id]
      );
    }

    /* ---------- APPLY (explicit re-apply / drift correction) ---------- */

    if (action === 'APPLY') {

      await runTerraformForTenant(op.tenant_id);
    }

    /* ---------- MIGRATE ---------- */

    if (action === 'MIGRATE') {

      if (!op.migration_file) {
        throw new Error("migration file missing");
      }

      await pool.query(
        `UPDATE tenant_operations
         SET status='MIGRATING',
             progress=2,
             message='preparing database'
         WHERE id=$1`,
        [operationId]
      );

      await pool.query(
        `UPDATE tenants SET active_pipeline='MIGRATING' WHERE id=$1`,
        [op.tenant_id]
      );

      await provisionDatabase(op.tenant_id);

      await runMigration(op.tenant_id, op.migration_file, operationId);

      await restartBackendDeployment(op.tenant_id);
    }

    /* ---------- SUCCESS ---------- */

    await pool.query(
      `UPDATE tenant_operations
       SET status='SUCCESS',
           finished_at=now(),
           progress=100,
           message='completed'
       WHERE id=$1`,
      [operationId]
    );

    await pool.query(
      `UPDATE tenants SET active_pipeline=NULL WHERE id=$1`,
      [op.tenant_id]
    );

    await pool.query(
      `UPDATE operation_queue SET status='DONE' WHERE operation_id=$1`,
      [operationId]
    );

    console.log(`Operation ${operationId} completed`);
  }
  catch (err) {

    console.error(err);

    await pool.query(
      `UPDATE tenant_operations
       SET status='FAILED',
           finished_at=now(),
           message=$2
       WHERE id=$1`,
      [operationId, err.toString()]
    );

    await pool.query(
      `UPDATE tenants SET active_pipeline=NULL WHERE id=$1`,
      [op?.tenant_id]
    );

    await pool.query(
      `UPDATE operation_queue SET status='FAILED' WHERE operation_id=$1`,
      [operationId]
    );
  }
}

/* ============================================================
   MAIN LOOP
============================================================ */

async function main() {

  console.log("Terraform worker started");

  process.on("SIGTERM", async () => {
    await pool.end();
    process.exit(0);
  });

  await pool.query(
    `UPDATE operation_queue
     SET status='FAILED'
     WHERE status='RUNNING'
     AND locked_at < now() - interval '1 hour'`
  );

  console.log("Recovered stuck RUNNING jobs");

  while (true) {

    try {

      const opId = await fetchJob();

      if (!opId) {
        await sleep(5000);
        continue;
      }

      await processJob(opId);
    }
    catch (err) {
      console.error("Worker loop error:", err);
      await sleep(5000);
    }
  }
}

main();