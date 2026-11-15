export class AccountMutationQueue {
  constructor(){this.tail=Promise.resolve();this.pending=0;}
  run(action){
    if(this.pending>=128)return Promise.reject(Error('Account work queue is full'));
    this.pending++;
    const result=this.tail.catch(()=>{}).then(action);
    this.tail=result.catch(()=>{}).finally(()=>this.pending--);
    return result;
  }
}

// One live writer per origin/identity. A closed tab releases the browser lock.
export async function acquireAccountLease(owner,existing=null){
  if(existing?.owner===owner)return existing;
  if(!globalThis.navigator?.locks)throw Error('This browser needs Web Locks for saved identities.');
  let resolveAcquired,rejectAcquired,release;
  const acquired=new Promise((resolve,reject)=>{resolveAcquired=resolve;rejectAcquired=reject;});
  const held=new Promise(resolve=>release=resolve);
  void navigator.locks.request(`chta-web-active-identity:${owner}`,{ifAvailable:true},async lock=>{
    if(!lock){rejectAcquired(Error('This identity is open in another tab. Switch or close that tab first.'));return;}
    resolveAcquired({owner,release});await held;
  }).catch(rejectAcquired);
  return acquired;
}
