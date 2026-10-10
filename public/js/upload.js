(function () {
  'use strict';

  var CONCURRENCY = 2;
  var MAX_ATTEMPTS = 3;

  var root = document.getElementById('uploader');
  var input = document.getElementById('files');
  var guestInput = document.getElementById('guest');
  var list = document.getElementById('list');
  var summary = document.getElementById('summary');
  var retryButton = document.getElementById('retry');
  var code = root.dataset.code || '';

  var queue = [];
  var items = [];
  var active = 0;
  var wakeLock = null;

  try { guestInput.value = localStorage.getItem('guestName') || ''; } catch (e) {}
  guestInput.addEventListener('change', function () {
    try { localStorage.setItem('guestName', guestInput.value.trim()); } catch (e) {}
  });

  input.addEventListener('change', function () {
    Array.prototype.forEach.call(input.files, addFile);
    input.value = '';
    pump();
  });

  retryButton.addEventListener('click', function () {
    items.forEach(function (item) {
      if (item.state === 'error') {
        item.attempts = 0;
        setState(item, 'queued', 'En attente…');
        queue.push(item);
      }
    });
    pump();
  });

  function addFile(file) {
    var li = document.createElement('li');
    li.className = 'file';
    li.innerHTML =
      '<div class="file-row"><span class="file-name"></span><span class="file-status"></span></div>' +
      '<div class="bar"><div class="bar-fill"></div></div>';
    li.querySelector('.file-name').textContent = file.name || 'photo';
    list.insertBefore(li, list.firstChild);

    var item = { file: file, el: li, attempts: 0, state: 'queued' };
    setState(item, 'queued', 'En attente…');
    items.push(item);
    queue.push(item);
  }

  function setState(item, state, label, progress) {
    item.state = state;
    item.el.dataset.state = state;
    item.el.querySelector('.file-status').textContent = label;
    var fill = item.el.querySelector('.bar-fill');
    fill.style.width = (state === 'done' ? 100 : (progress || 0)) + '%';
    updateSummary();
  }

  function updateSummary() {
    var done = 0, failed = 0, pending = 0;
    items.forEach(function (i) {
      if (i.state === 'done') done++;
      else if (i.state === 'error') failed++;
      else pending++;
    });
    summary.hidden = items.length === 0;
    retryButton.hidden = failed === 0 || pending > 0;
    if (pending > 0) {
      summary.textContent = 'Envoi en cours… ' + done + ' / ' + items.length;
      summary.className = 'summary';
    } else if (failed > 0) {
      summary.textContent = done + ' envoyé(s), ' + failed + ' en échec.';
      summary.className = 'summary warn';
    } else {
      summary.textContent = 'Merci ! ' + done + ' fichier(s) bien reçu(s) 💛';
      summary.className = 'summary ok';
    }
    toggleWakeLock(pending > 0);
  }

  function pump() {
    while (active < CONCURRENCY && queue.length) {
      upload(queue.shift());
    }
  }

  function upload(item) {
    active++;
    item.attempts++;
    setState(item, 'uploading', 'Préparation…');

    createSession(item.file)
      .then(function (uploadUrl) { return putFile(item, uploadUrl); })
      .then(function () {
        setState(item, 'done', 'Envoyé ✓');
      })
      .catch(function (err) {
        if (!err.fatal && item.attempts < MAX_ATTEMPTS) {
          setState(item, 'queued', 'Nouvel essai…');
          queue.push(item);
        } else {
          setState(item, 'error', err.message || 'Échec');
        }
      })
      .then(function () {
        active--;
        pump();
      });
  }

  function createSession(file) {
    return fetch('/api/upload-session', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        name: file.name,
        type: file.type,
        size: file.size,
        guest: guestInput.value.trim(),
        code: code
      })
    }).then(function (res) {
      return res.json().catch(function () { return {}; }).then(function (data) {
        if (res.ok && data.uploadUrl) return data.uploadUrl;
        var err = new Error(data.error || 'Erreur serveur');
        // 4xx (wrong type, too big, bad code) won't succeed on retry.
        err.fatal = res.status >= 400 && res.status < 500;
        throw err;
      });
    }, function () {
      throw new Error('Pas de connexion');
    });
  }

  function putFile(item, uploadUrl) {
    return new Promise(function (resolve, reject) {
      var xhr = new XMLHttpRequest();
      xhr.open('PUT', uploadUrl);
      xhr.upload.onprogress = function (e) {
        if (!e.lengthComputable) return;
        var pct = Math.round((e.loaded / e.total) * 100);
        setState(item, 'uploading', pct + ' %', pct);
      };
      xhr.onload = function () {
        if (xhr.status === 200 || xhr.status === 201) resolve();
        else reject(new Error('Échec de l’envoi (' + xhr.status + ')'));
      };
      xhr.onerror = function () { reject(new Error('Connexion interrompue')); };
      xhr.send(item.file);
    });
  }

  // Keep the screen awake while uploading so the phone doesn't pause it.
  function toggleWakeLock(on) {
    if (!('wakeLock' in navigator)) return;
    if (on && !wakeLock) {
      navigator.wakeLock.request('screen').then(function (lock) {
        wakeLock = lock;
        lock.addEventListener('release', function () { wakeLock = null; });
      }).catch(function () {});
    } else if (!on && wakeLock) {
      wakeLock.release().catch(function () {});
      wakeLock = null;
    }
  }

  window.addEventListener('beforeunload', function (e) {
    if (active > 0 || queue.length > 0) {
      e.preventDefault();
      e.returnValue = '';
    }
  });
})();
