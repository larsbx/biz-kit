const {chromium}=require('playwright');
const fs=require('fs');
const os=require('os');
const path=require('path');
const assert=require('assert/strict');
(async()=>{
const browser=await chromium.launch({headless:true});
const context=await browser.newContext({acceptDownloads:true,viewport:{width:390,height:844}});
const page=await context.newPage();const errors=[],remote=[];
page.on('pageerror',e=>errors.push(e.message));page.on('request',r=>{if(!r.url().startsWith('file:')&&!r.url().startsWith('blob:'))remote.push(r.url())});
page.on('dialog',d=>d.accept());
const base=__dirname;
const temporary=fs.mkdtempSync(path.join(os.tmpdir(),'pilot-form-test-'));
const bundle=JSON.parse(fs.readFileSync(base+'/intake.synthetic.json'));
await page.goto('file://'+base+'/intake.html');
const outputs=[];
for(const collection of ['merchants','requests','invitations','quotes','fee_arrangements','orders','costs']){
 await page.selectOption('#kind',collection);
 const record=bundle[collection][0];
 await page.evaluate(({collection,record})=>{
 function fill(schema,value,box){
  let body=box;
  if(schema.nullable&&schema.type==='object'){
    const toggle=box.querySelector(':scope > input[type=checkbox]');toggle.checked=value===null;toggle.dispatchEvent(new Event('change'));if(value===null)return;body=box.querySelector(':scope > div');
  }
  if(schema.type==='object'){
    const children=[...body.querySelectorAll(':scope > [data-key]')];
    for(const [key,s] of Object.entries(schema.fields)){const child=children.find(x=>x.dataset.key===key);if(!child)throw Error('missing UI field '+key);fill(s,value[key],child)}
  }else if(schema.type==='array'){
    const list=body.querySelector(':scope > div'),add=body.querySelector(':scope > button');
    while(list.children.length<value.length)add.click();
    if(list.children.length!==value.length)throw Error('array size mismatch');
    [...list.children].forEach((item,i)=>fill(schema.item,value[i],item.querySelector(':scope > [data-key]')));
  }else{const input=body.querySelector(':scope > input,:scope > select');input.value=value===null?'':String(value);input.dispatchEvent(new Event('input'));input.dispatchEvent(new Event('change'));}
 }
 fill(schemas[collection],record,document.querySelector('#fields > fieldset'));
 },{collection,record});
 const invalid=await page.locator('form :invalid').evaluateAll(xs=>xs.map(x=>({id:x.id,value:x.value,pattern:x.pattern})));
 if(invalid.length)throw Error(collection+' invalid: '+JSON.stringify(invalid));
 const promise=page.waitForEvent('download');await page.getByRole('button',{name:'Download prepared record',exact:true}).click();
 const download=await promise;const saved=path.join(temporary,collection+'.json');await download.saveAs(saved);
 const parsed=JSON.parse(fs.readFileSync(saved));
 assert.deepEqual(parsed.record,record,collection+' record mismatch');outputs.push(collection);
}
const overflow=await page.evaluate(()=>document.documentElement.scrollWidth>window.innerWidth);
if(overflow)throw Error('mobile horizontal overflow');
await page.setViewportSize({width:1280,height:900});
if(await page.evaluate(()=>document.documentElement.scrollWidth>window.innerWidth))throw Error('desktop horizontal overflow');
console.log(JSON.stringify({forms:outputs,errors,remote,mobileOverflow:overflow}));
if(errors.length||remote.length)throw Error('browser error or unexpected network request');
await browser.close();
fs.rmSync(temporary,{recursive:true,force:true});
})();
