/**
 * OTS Genesis Generator
 *
 * Generates CopyrightRegistry contract bytecode for genesis block allocation.
 *
 * Usage:
 *   node scripts/generate-ots.js [options]
 *
 * Options:
 *   --output <file>    Output file (default: ./genesis-ots.json)
 *   --merge <file>     Merge into existing genesis.json
 *   --admin <address>  Admin address for contract initialization
 *
 * Examples:
 *   node scripts/generate-ots.js
 *   node scripts/generate-ots.js --output genesis-ots.json
 *   node scripts/generate-ots.js --merge genesis.json --output genesis-final.json
 */

const program = require('commander');
const nunjucks = require('nunjucks');
const fs = require('fs');

program.version('1.0.0');
program.option('-o, --output <output-file>', 'Output file', './genesis-ots.json');
program.option('-t, --template <template>', 'OTS template file', './genesis-template-ots.json');
program.option('-m, --merge <genesis-file>', 'Merge into existing genesis.json');
program.option('-a, --admin <address>', 'Admin address', '0x0000000000000000000000000000000000000000');
program.parse(process.argv);

const OTS_CONTRACTS = {
  copyrightRegistry: {
    address: '0x0000000000000000000000000000000000009000',
    artifact: 'out/CopyrightRegistry.sol/CopyrightRegistry.json'
  }
};

function readByteCode(name, artifactPath) {
  return new Promise((resolve, reject) => {
    fs.readFile(artifactPath, 'utf8', (err, data) => {
      if (err) {
        reject(new Error(`Error reading ${artifactPath}: ${err.message}`));
        return;
      }

      try {
        const jsonObj = JSON.parse(data);
        const deployedBytecode = jsonObj['deployedBytecode']['object'];

        if (!deployedBytecode) {
          reject(new Error(`No deployedBytecode found in ${artifactPath}`));
          return;
        }

        resolve({
          name: name,
          bytecode: deployedBytecode
        });
      } catch (parseError) {
        reject(new Error(`Error parsing ${artifactPath}: ${parseError.message}`));
      }
    });
  });
}

async function main() {
  console.log('='.repeat(60));
  console.log('OTS Genesis Generator');
  console.log('='.repeat(60));

  // Read contract bytecodes
  console.log('\n1. Reading compiled contract bytecodes...');

  const bytecodePromises = Object.entries(OTS_CONTRACTS).map(([name, config]) => {
    return readByteCode(name, config.artifact);
  });

  let bytecodes;
  try {
    bytecodes = await Promise.all(bytecodePromises);
  } catch (error) {
    console.error(`\nError: ${error.message}`);
    console.error('\nMake sure to run "forge build" first!');
    process.exit(1);
  }

  // Build template data
  const data = {};
  bytecodes.forEach(({ name, bytecode }) => {
    data[name] = bytecode;
    console.log(`   ${name}: ${bytecode.length} bytes`);
  });

  // Generate OTS genesis allocation
  console.log('\n2. Generating OTS genesis allocation...');

  const templateString = fs.readFileSync(program.template).toString();
  const otsAlloc = JSON.parse(nunjucks.renderString(templateString, data));

  // If merge option specified, merge into existing genesis
  if (program.merge) {
    console.log(`\n3. Merging into ${program.merge}...`);

    const existingGenesis = JSON.parse(fs.readFileSync(program.merge));

    // Merge alloc sections
    Object.assign(existingGenesis.alloc, otsAlloc.alloc);

    // Write merged genesis
    fs.writeFileSync(program.output, JSON.stringify(existingGenesis, null, 2));
    console.log(`   Merged genesis written to: ${program.output}`);
  } else {
    // Write standalone OTS genesis
    fs.writeFileSync(program.output, JSON.stringify(otsAlloc, null, 2));
    console.log(`   OTS genesis written to: ${program.output}`);
  }

  // Summary
  console.log('\n' + '='.repeat(60));
  console.log('OTS CONTRACT ADDRESSES');
  console.log('='.repeat(60));
  Object.entries(OTS_CONTRACTS).forEach(([name, config]) => {
    console.log(`${name.padEnd(20)}: ${config.address}`);
  });
  console.log('='.repeat(60));

  console.log('\nTo use these contracts in RMC:');
  console.log('1. Merge alloc into your genesis.json');
  console.log('2. Configure RMC node with:');
  console.log('   [Eth.OTS]');
  console.log('   Enabled = true');
  console.log('   Mode = "full"');
  console.log(`   ContractAddress = "${OTS_CONTRACTS.copyrightRegistry.address}"`);
  console.log('='.repeat(60));
}

main().catch(error => {
  console.error('Fatal error:', error);
  process.exit(1);
});
