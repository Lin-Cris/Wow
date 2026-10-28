// Explicit Simulator-only test fixture. Never reads or writes an Obsidian vault.
import {execFileSync} from 'node:child_process';
import {mkdir,writeFile} from 'node:fs/promises';
import {join} from 'node:path';
const simulator=process.argv[2];
if(!simulator) throw new Error('Usage: node scripts/prepare-ios-picker-test.mjs SIMULATOR_UDID (install CheckBot first)');
const container=execFileSync('xcrun',['simctl','get_app_container',simulator,'com.chris.CheckBot','data'],{encoding:'utf8'}).trim();
const folder=join(container,'Documents','Plan-Test');
await mkdir(folder,{recursive:true});
const now=new Date();
const name=`${now.getFullYear()}年${now.getMonth()+1}月${now.getDate()}日`;
await writeFile(join(folder,`${name}.md`),`# ${name}\n### 00:00–23:59｜Folder picker test plan\n- [ ] **Behavior：**Simulator fixture only\n`);
console.log('Prepared isolated Plan-Test fixture for Files picker UI test.');
