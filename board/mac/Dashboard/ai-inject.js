
(function(){
  if (window.__dsV4) return; window.__dsV4 = true;

  function tagCls(n){
    try {
      var c = n.className ? String(n.className) : '';
      return n.tagName + (c ? ('.' + c.split(' ').join('.')) : '');
    } catch(e){ return '?'; }
  }

  // 助手消息正文节点。
  // 注意：站点用的是虚拟列表（.ds-virtual-list-visible-items），
  // 屏幕上滚出去的旧消息会被从 DOM 移除 —— 所以节点数量会自己变（1↔2），
  // 绝不能用「节点数变多」来判断有没有新回复（这是 v4 收不到回复的根因）。
  function asstNodes(){
    var n = document.querySelectorAll('.ds-markdown.ds-assistant-message-main-content');
    if (n.length) return n;
    n = document.querySelectorAll('[class*="assistant-message-main-content"]');
    if (n.length) return n;
    n = document.querySelectorAll('.ds-message .ds-markdown, .ds-markdown');
    if (n.length) return n;
    return document.querySelectorAll('div[class*="markdown"]');
  }

  // 取「内容指纹」：只留前 300 字，用来跟发送前的快照比对
  function fp(s){ return clean(s).slice(0, 300); }

  function snapList(){
    var nodes = asstNodes(), a = [];
    for (var i = 0; i < nodes.length; i++){
      var f = fp(txt(nodes[i]));
      if (f) a.push(f);
    }
    return a;
  }

  function inputEl(){
    return document.querySelector('textarea') || document.querySelector('div[contenteditable="true"]');
  }

  function ctlList(){
    return document.querySelectorAll('button, [role="button"], .ds-icon-button, div[class*="send"]');
  }

  function labelOf(n){
    var s = '';
    try { s += (n.getAttribute('aria-label') || ''); } catch(e){}
    try { s += '|' + (n.getAttribute('title') || ''); } catch(e){}
    try { s += '|' + (n.className ? String(n.className) : ''); } catch(e){}
    try { s += '|' + ((n.textContent || '') + '').slice(0, 40); } catch(e){}
    return s.toLowerCase();
  }

  function txt(n){ try { return ((n.innerText || '') + ''); } catch(e){ return ''; } }

  // 去掉回复末尾夹杂的界面按钮文字
  function clean(s){
    s = ((s || '') + '').trim();
    if (!s) return '';
    var markers = ['重新生成','继续生成','复制','分享','深度思考','联网搜索','深入搜索',
                   '给 DeepSeek 发送消息','给DeepSeek发送消息','DeepSeek 也可能会犯错','内容由 AI 生成',
                   'Regenerate','Copy','Share','Message DeepSeek','DeepSeek can make mistakes',
                   '停止生成','Stop generating'];
    var cut = s.length;
    for (var i = 0; i < markers.length; i++){
      var p = s.indexOf(markers[i]);
      if (p >= 0 && p < cut) cut = p;
    }
    if (cut < s.length * 0.35) cut = s.length;   // 别把正文里出现的这些词误伤
    var r = s.slice(0, cut).trim();
    // 生成中时页面会显示“思考中/正在生成”之类的前缀
    var heads = ['思考中','正在生成','Thinking','思考过程'];
    for (var j = 0; j < heads.length; j++){
      if (r.indexOf(heads[j]) === 0) r = r.slice(heads[j].length).trim();
    }
    return r;
  }

  window.__dsProbe = function(){
    var o = {u:'', c:-1, t:[], st:false, ta:'', tal:-1, ai:false, fi:false, tt:'', err:''};
    try{
      o.u = location.href;
      o.tt = ((document.title || '') + '').slice(0, 80);
      o.fi = !!document.querySelector('input[type=file]');
      var el = inputEl();
      o.ai = !!el;
      var full = el ? ((el.tagName === 'TEXTAREA') ? (el.value || '') : (el.textContent || '')) : '__NONE__';
      o.tal = (full === '__NONE__') ? -1 : full.length;   // 完整长度（用于判断输入框是否被清空）
      o.ta = (full === '__NONE__') ? '__NONE__' : full.slice(0, 120);  // 只回传前缀，避免长文本把通道塞满
      var nodes = asstNodes();
      o.c = nodes.length;
      for (var i = 0; i < nodes.length; i++){ o.t.push(txt(nodes[i]).slice(0, 4000)); }
      var cs = ctlList();
      for (var j = 0; j < cs.length; j++){
        var l = labelOf(cs[j]);
        if (l.indexOf('stop') >= 0 || l.indexOf('停止') >= 0 || l.indexOf('interrupt') >= 0) o.st = true;
      }
      if (!o.st){
        // 有些版本按钮没有 label，靠 class 兜底
        if (document.querySelector('[class*="stop"], [class*="interrupt"]')) o.st = true;
      }
    }catch(e){ o.err = '' + e; }
    return JSON.stringify(o);
  };

  // 读取回复：内容指纹法（虚拟列表安全）+ 锚点法兜底
  //   snapJson = 发送前 asstNodes 的内容指纹快照（JSON 字符串）
  //   prevText = 上一轮的答案原文。必须显式跳过它 —— 发新问题时，
  //     旧答案一定还挂在页面上（虚拟列表只是把看不见的移出 DOM），
  //     一旦判重漏掉，它就会被当成本轮回复写进新气泡里，
  //     表现就是「新问题发出去先闪一遍上一个问题的完整答案」。
  window.__dsRead = function(text, snapJson, prevText){
    var o = {mode:'', node:'', cls:'', reply:'', md:0, found:false, err:''};
    try{
      var snap = [];
      try { snap = JSON.parse(snapJson || '[]') || []; } catch(e){ snap = []; }
      function inSnap(f){
        for (var i = 0; i < snap.length; i++){ if (snap[i] === f) return true; }
        return false;
      }
      var prev = clean(prevText || '');
      function isPrev(full){
        if (!prev || prev.length < 20) return false;
        if (full === prev) return true;
        // 流式输出到一半时是本轮内容；完整的旧答案则是 prev 的前缀或本身
        var head = prev.slice(0, 200);
        return (full.length >= 20 && (prev.indexOf(full) === 0 || full.indexOf(head) === 0));
      }
      var probe = clean(text);
      var nodes = asstNodes();
      o.md = nodes.length;
      // 从最新的往前找：内容不在快照里、不是我刚发的那句话、也不是上一轮的答案 → 才是本次回复
      for (var i = nodes.length - 1; i >= 0; i--){
        var full = clean(txt(nodes[i]));
        if (!full) continue;
        if (full === probe) continue;
        if (inSnap(full.slice(0, 300))) continue;
        if (isPrev(full)) continue;
        o.mode = 'snap'; o.reply = full; o.found = true;
        o.node = tagCls(nodes[i]);
        return JSON.stringify(o);
      }
      // ★ 走到这里 = 快照里找不到「新内容」。
      //   如果连一个比快照更新的助手节点都还没出现，就**别去猜**：
      //   下面的锚点法是从「我这句话」往后切页面文本，那一刻后面跟着的
      //   必然是**上一条答案** —— 这正是「新问题一发出去先闪一遍旧答案」
      //   的来源。老实地报「还没有」，让上层半秒后再问一次。
      if (snap.length && nodes.length <= snap.length){
        o.mode = 'wait';
        return JSON.stringify(o);
      }
      // 锚点法：找到包含我们这句话的、最深的那个元素
      var all = document.querySelectorAll('div,p,span,article,section,li');
      var best = null, bestLen = 0;
      for (var i = 0; i < all.length; i++){
        var t = txt(all[i]);
        if (t.indexOf(text) < 0) continue;
        if (best === null || t.length < bestLen){ best = all[i]; bestLen = t.length; }
      }
      if (!best){ o.mode = 'none'; return JSON.stringify(o); }
      o.node = tagCls(best);
      o.cls = ((best.className ? String(best.className) : '') + '');
      // 往上走，找到明显包含“更多内容”的祖先，就是消息容器
      var container = best;
      var up = best.parentElement;
      var hops = 0;
      while (up && up !== document.documentElement && hops < 12){
        if (txt(up).length > bestLen + 4){ container = up; break; }
        up = up.parentElement; hops++;
      }
      var cn = txt(container);
      var k = cn.lastIndexOf(text);
      var rep = (k >= 0) ? cn.slice(k + text.length) : '';
      var cr = clean(rep);
      // 锚点法唯一还允许用的场合是「asstNodes 的选择器整个失效」。
      // 但即便如此，也不许把它切成的那段**旧答案**当成本轮回复交上去 ——
      // 交上去就是那个闪回 bug。宁可这一轮什么都不显示。
      if (isPrev(cr) || inSnap(cr.slice(0, 300))){
        o.mode = 'stale';
        return JSON.stringify(o);
      }
      o.reply = cr;
      o.mode = 'anchor' + (container === best ? '(self)' : '(+' + hops + ')');
      o.found = o.reply.length > 0;
      return JSON.stringify(o);
    }catch(e){ o.err = '' + e; return JSON.stringify(o); }
  };

  window.__dsSend = function(text){
    var o = {base:-1, ok:'', snap:'[]'};
    try{
      // 发送前先给现有助手消息拍个「内容指纹快照」——虚拟列表下不能靠数量，只能靠内容
      var snap = snapList();
      o.snap = JSON.stringify(snap);
      o.base = snap.length;
      var el = inputEl();
      if (!el){ o.ok = 'NO_INPUT'; return JSON.stringify(o); }
      el.focus();
      if (el.tagName === 'TEXTAREA'){
        var d = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value');
        if (d && d.set) d.set.call(el, text); else el.value = text;
        el.dispatchEvent(new Event('input', {bubbles:true}));
        el.dispatchEvent(new Event('change', {bubbles:true}));
      } else {
        el.textContent = text;
        el.dispatchEvent(new Event('input', {bubbles:true}));
      }
      var ev = new KeyboardEvent('keydown', {key:'Enter', code:'Enter', keyCode:13, which:13, bubbles:true, cancelable:true});
      el.dispatchEvent(ev);
      o.ok = 'ENTER';
      return JSON.stringify(o);
    }catch(e){ o.ok = 'ERR:' + e; return JSON.stringify(o); }
  };

  window.__dsClickSend = function(){
    try{
      var cs = ctlList();
      for (var i = cs.length - 1; i >= 0; i--){
        var n = cs[i];
        try { if (n.getAttribute('aria-disabled') === 'true') continue; } catch(e){}
        if (n.disabled) continue;
        var l = labelOf(n);
        if (l.indexOf('send') >= 0 || l.indexOf('发送') >= 0 || l.indexOf('arrow-up') >= 0 || l.indexOf('paper-plane') >= 0){
          n.click(); return 'CLICKED:' + labelOf(n).slice(0, 50);
        }
      }
      return 'NO_SEND_CONTROL';
    }catch(e){ return 'ERR:' + e; }
  };

  window.__dsUploadMulti = function(jsonStr){
    try{
      var fi = document.querySelector('input[type=file]');
      if (!fi) return 'NO_FILE_INPUT';
      var items = JSON.parse(jsonStr);
      var dt = new DataTransfer();
      for (var k = 0; k < items.length; k++){
        var it = items[k];
        var bin = atob(it.b64);
        var arr = new Uint8Array(bin.length);
        for (var i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
        dt.items.add(new File([arr], it.name, {type: it.mime || 'application/octet-stream'}));
      }
      fi.files = dt.files;
      fi.dispatchEvent(new Event('input', {bubbles:true}));
      fi.dispatchEvent(new Event('change', {bubbles:true}));
      return 'OK';
    }catch(e){ return 'ERR:' + e; }
  };

  // 真正撤掉已附加的文件：清空 file input + 点掉页面上的文件卡片
  window.__dsClearFiles = function(){
    try{
      var n = 0;
      var fi = document.querySelector('input[type=file]');
      if (fi){
        try { fi.value = ''; } catch(e){}
        try { fi.files = new DataTransfer().files; } catch(e){}
        try { fi.dispatchEvent(new Event('input', {bubbles:true})); } catch(e){}
        try { fi.dispatchEvent(new Event('change', {bubbles:true})); } catch(e){}
        n++;
      }
      var cands = document.querySelectorAll('[class*="file"],[class*="attach"],[class*="upload"],[class*="card"],[class*="chip"]');
      var hitWords = ['close','remove','delete','cancel','clear','删除','移除','取消'];
      for (var i = 0; i < cands.length; i++){
        var c = cands[i];
        var t = txt(c);
        if (!t || t.length > 80) continue;
        var btns = c.querySelectorAll('[class*="close"],[class*="remove"],[class*="delete"],[class*="clear"],[role="button"],button,svg,use');
        for (var j = 0; j < btns.length; j++){
          var b = btns[j];
          var lb = labelOf(b);
          try {
            lb += '|' + (b.getAttribute('href') || '') + '|' + (b.getAttribute('xlink:href') || '') + '|' +
                  (b.getAttribute('aria-label') || '');
          } catch(e){}
          var hit = false;
          for (var w = 0; w < hitWords.length; w++){ if (lb.indexOf(hitWords[w]) >= 0) hit = true; }
          if (!hit) continue;
          try { b.click(); n++; } catch(e){}
          break;
        }
      }
      return 'OK:' + n;
    }catch(e){ return 'ERR:' + e; }
  };

  // 附件状态自查：file input 里有几个、输入区显示了什么、有没有可点的删除按钮
  window.__dsFilesInfo = function(){
    var o = {n:-1, names:[], chain:[], hits:[]};
    try{
      var fi = document.querySelector('input[type=file]');
      if (fi && fi.files){
        o.n = fi.files.length;
        for (var i = 0; i < fi.files.length; i++) o.names.push(fi.files[i].name);
      }
      // 从输入框往上爬 12 层，看哪一层开始出现文件名 / 缩略图
      var el = inputEl(), up = el;
      for (var k = 0; k < 12 && up; k++){
        var t = txt(up);
        o.chain.push(tagCls(up) + ' len' + t.length + ' :: ' + t.slice(0, 120).split('\n').join(' '));
        var hasName = (t.indexOf('.png') >= 0 || t.indexOf('.pdf') >= 0 || t.indexOf('.jpg') >= 0 ||
                       t.indexOf('截图') >= 0 || t.indexOf('selftest') >= 0);
        var hasImg = false;
        try { hasImg = !!up.querySelector('img[src^="blob:"], img[src^="data:"]'); } catch(e){}
        if ((hasName || hasImg) && o.hits.length < 3){
          var bs = up.querySelectorAll('[role="button"],button,svg,use,[class*="icon"],[class*="close"],[class*="remove"],[class*="del"]');
          var bl = [];
          for (var j = 0; j < bs.length && bl.length < 30; j++) bl.push(labelOf(bs[j]).slice(0, 90));
          o.hits.push({cls: tagCls(up), text: t.slice(0, 200), imgs: (function(){
            var a = [], ii = up.querySelectorAll('img'); for (var z = 0; z < ii.length && a.length < 5; z++) a.push(((ii[z].src||'') + '').slice(0, 60)); return a;
          })(), btns: bl, html: ((up.outerHTML || '') + '').slice(0, 2600)});
        }
        up = up.parentElement;
      }
      return JSON.stringify(o);
    }catch(e){ o.err = '' + e; return JSON.stringify(o); }
  };

  window.__dsToken = function(){
    try { return localStorage.getItem('userToken') || ''; } catch(e){ return ''; }
  };

  window.__dsDiag = function(){
    var o = {u:'', title:'', sels:{}, classes:{}, outline:'', btns:[], probe:null, err:''};
    try{
      o.u = location.href; o.title = document.title;
      var sels = ['textarea','div[contenteditable="true"]','.ds-markdown',
                  '.ds-markdown.ds-assistant-message-main-content','div[class*="markdown"]',
                  'input[type=file]','button','[role="button"]','.ds-icon-button','[class*="_assistant"]',
                  '[class*="message"]','[class*="virtual"]','[class*="chat"]','[class*="conversation"]'];
      for (var i = 0; i < sels.length; i++){
        try { o.sels[sels[i]] = document.querySelectorAll(sels[i]).length; } catch(e){ o.sels[sels[i]] = -1; }
      }
      // 类名清单（有助于找出真正的消息容器）
      var all = document.querySelectorAll('*');
      for (var k = 0; k < all.length; k++){
        var c = all[k].className ? String(all[k].className) : '';
        if (!c) continue;
        var parts = c.split(' ');
        for (var j = 0; j < parts.length; j++){
          var p = parts[j];
          if (!p || p.length > 60) continue;
          o.classes[p] = (o.classes[p] || 0) + 1;
        }
      }
      // DOM 大纲：有正文的元素（标签.类名 深度 字数）
      var lines = [];
      for (var m = 0; m < all.length && lines.length < 260; m++){
        var e = all[m];
        var t = txt(e);
        if (t.length < 20 || t.length > 60000) continue;
        var depth = 0, p2 = e.parentElement;
        while (p2 && depth < 40){ depth++; p2 = p2.parentElement; }
        lines.push(tagCls(e) + ' d' + depth + ' len' + t.length + ' :: ' + t.slice(0, 60).split('\n').join(' '));
      }
      o.outline = lines.join('\n');
      // 所有可点击控件的标签（用于认出真正的“发送”按钮）
      var bs = document.querySelectorAll('[role="button"], button, [class*="button"], [class*="icon"]');
      for (var z = 0; z < bs.length && o.btns.length < 60; z++){
        o.btns.push(bs[z].tagName + ' :: ' + labelOf(bs[z]).slice(0, 110));
      }
      o.probe = JSON.parse(window.__dsProbe());
    }catch(e){ o.err = '' + e; }
    return JSON.stringify(o);
  };
})();
