// Run in a disposable playwright-cli session opened on the helper server's
// /new/index.html. The helper is scripts/serve_web_identity_checks.mjs.
// Optional qaCompareOld=true compares an explicitly prepared old fixture.
async page=>{
 const origin=await page.evaluate(()=>location.origin);
 const browser=page.context().browser(),report=[];
 const compareOld=await page.evaluate(()=>globalThis.qaCompareOld===true);
 for(const revision of compareOld?['old','new']:['new']){
  for(const scenario of ['overlap','pin-cleanup','profile-alias','avatar','tabs']){
   const context=await browser.newContext(),tab=await context.newPage();
   try{
    await tab.goto(`${origin}/${revision}/index.html`);
    await tab.waitForFunction(()=>!!globalThis.chtCore);
    await tab.evaluate(async()=>{
      await chtCore.ready;
      const draft=JSON.parse(await chtCore.createIdentity());
      const identity=JSON.parse(await chtCore.confirmRecovery(draft.mnemonic));
      globalThis.qaOwner=identity.id;
    });
    if(scenario==='overlap'){
      await tab.evaluate(async()=>{
        const original=IDBObjectStore.prototype.put;let failed=false;
        IDBObjectStore.prototype.put=function(value,key){if(!failed&&key===`web-vault-v1:account:${qaOwner}`){failed=true;throw Error('injected disk failure');}return original.call(this,value,key);};
        try{
          const result=await Promise.allSettled([chtCore.sendText('general','A should fail',1),chtCore.sendText('general','B must survive',2)]);
          if(result[0].status!=='rejected'||result[1].status!=='fulfilled')throw Error('Failure fixture did not exercise overlap');
          const snapshot=await chtCore.snapshot();
          if(!snapshot.includes('B must survive')||snapshot.includes('A should fail'))throw Error('Rollback lost successful message or kept failed message');
        }finally{IDBObjectStore.prototype.put=original;}
      });
    }else if(scenario==='pin-cleanup'){
      await tab.evaluate(async()=>{
        const put=IDBObjectStore.prototype.put,remove=IDBObjectStore.prototype.delete;let failed=false;
        function intercept(key){if(!failed&&key==='identity-secret'){failed=true;throw Error('injected cleanup failure');}}
        IDBObjectStore.prototype.put=function(v,k){intercept(k);return put.call(this,v,k);};
        IDBObjectStore.prototype.delete=function(k){intercept(k);return remove.call(this,k);};
        try{
          let rejected=false;try{await chtCore.rememberIdentity('573921','Synthetic Alpha','');}catch{rejected=true;}
          if(!rejected)throw Error('Cleanup failure was not injected');
          await chtCore.rememberIdentity('573921','Synthetic Alpha','');
          await chtCore.lockIdentity();await chtCore.unlockIdentity(qaOwner,'573921');
        }finally{IDBObjectStore.prototype.put=put;IDBObjectStore.prototype.delete=remove;}
      });
    }else if(scenario==='profile-alias'){
      await tab.evaluate(async()=>{
        const original=Storage.prototype.setItem;
        Storage.prototype.setItem=function(){throw new DOMException('injected quota failure','QuotaExceededError');};
        try{await chtCore.rememberIdentity('573921','Synthetic Alpha','');await chtCore.lockIdentity();await chtCore.unlockIdentity(qaOwner,'573921');}
        finally{Storage.prototype.setItem=original;}
        if(JSON.parse(await chtCore.identity()).id!==qaOwner)throw Error('Activation failed under alias quota');
      });
    }else if(scenario==='avatar'){
      await tab.evaluate(async()=>{
        const canvas=document.createElement('canvas');canvas.width=48;canvas.height=48;
        const paint=canvas.getContext('2d');paint.fillStyle='green';paint.fillRect(0,0,48,48);
        const image=canvas.toDataURL('image/jpeg',0.35).split(',')[1];
        await chtCore.rememberIdentity('573921','Synthetic Alpha',image,image);
        const offer=JSON.parse(await chtCore.createPeerOffer('','Synthetic Alpha'));
        const card=JSON.parse(offer.contactCard);
        if(card.avatar!==image)throw Error('Offer card lost avatar');
        await chtCore.closePeer();
      });
    }else{
      await tab.evaluate(async()=>{await chtCore.rememberIdentity('573921','Synthetic Alpha','');await chtCore.sendText('general','Original tab message',1);});
      const other=await context.newPage();await other.goto(`${origin}/${revision}/index.html`);await other.waitForFunction(()=>!!globalThis.chtCore);
      const owner=await tab.evaluate(()=>qaOwner);
      const rejected=await other.evaluate(async id=>{await chtCore.ready;try{await chtCore.unlockIdentity(id,'573921');return false;}catch(e){if(!String(e).includes('another tab'))throw e;return true;}},owner);
      if(!rejected)throw Error('A second stale account writer was allowed');
      await tab.evaluate(()=>chtCore.lockIdentity());
      await other.evaluate(async id=>{await chtCore.unlockIdentity(id,'573921');if(!(await chtCore.snapshot()).includes('Original tab message'))throw Error('History missing after tab handover');},owner);
      await other.close();
    }
    report.push({revision,scenario,pass:true});
   }catch(error){report.push({revision,scenario,pass:false,error:String(error).split('\n')[0]});}
   finally{await context.close();}
  }
 }
 console.log(JSON.stringify(report));
 await page.evaluate(value=>globalThis.qaIdentityReport=value,report);
 const failures=report.filter(r=>r.revision==='new'&&!r.pass);
 if(failures.length)throw Error(JSON.stringify(failures));
 if(compareOld&&report.filter(r=>r.revision==='old'&&!r.pass).length<4)throw Error('Old revision did not reproduce review regressions');
}
