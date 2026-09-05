const { Client } = require('pg');
const fs = require('fs');
const path = require('path');

const connectionString = process.env.DATABASE_URL || 'postgresql://neondb_owner:npg_fb5l1egYcShw@ep-floral-bread-a7mlqwps-pooler.ap-southeast-2.aws.neon.tech/neondb?sslmode=require';

async function main() {
  const client = new Client({
    connectionString,
    ssl: { rejectUnauthorized: false }
  });

  try {
    console.log('Connecting to Neon PostgreSQL...');
    await client.connect();
    console.log('Connected successfully!');

    const schemaPath = path.join(__dirname, 'schema.sql');
    console.log('Reading schema file from:', schemaPath);
    const schemaSql = fs.readFileSync(schemaPath, 'utf8');

    console.log('Executing schema.sql...');
    await client.query(schemaSql);
    console.log('Schema executed successfully!');

    const res = await client.query(
      "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' ORDER BY table_name"
    );
    console.log('\n--- Live Neon PostgreSQL Tables (' + res.rows.length + ') ---');
    res.rows.forEach(r => console.log('  [OK] ' + r.table_name));

  } catch (err) {
    console.error('Migration error:', err);
  } finally {
    await client.end();
  }
}

main();
