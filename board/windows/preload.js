'use strict';
/* 渲染进程只能通过这里暴露的 API 与主进程通信（contextIsolation 打开，零 node 权限） */

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('mb', {
  bootstrap: () => ipcRenderer.invoke('app:bootstrap'),
  getData: (force) => ipcRenderer.invoke('data:get', force),

  login: (p) => ipcRenderer.invoke('auth:login', p),
  logout: () => ipcRenderer.invoke('auth:logout'),
  forgetCreds: () => ipcRenderer.invoke('auth:forget'),
  openLoginWindow: () => ipcRenderer.invoke('auth:openWindow'),

  setSettings: (partial) => ipcRenderer.invoke('settings:set', partial),
  resetSettings: () => ipcRenderer.invoke('settings:reset'),
  applyPreset: (id) => ipcRenderer.invoke('settings:preset', id),

  teams: () => ipcRenderer.invoke('teams:get'),
  teamsRefresh: () => ipcRenderer.invoke('teams:refresh'),
  teamsLogin: () => ipcRenderer.invoke('teams:login'),
  teamsLogout: () => ipcRenderer.invoke('teams:logout'),

  open: (url) => ipcRenderer.invoke('shell:open', url),
  revealSettings: () => ipcRenderer.invoke('shell:reveal'),

  winMin: () => ipcRenderer.invoke('win:min'),
  winMax: () => ipcRenderer.invoke('win:max'),
  winClose: () => ipcRenderer.invoke('win:close'),
  quit: () => ipcRenderer.invoke('app:quit'),
  relaunch: () => ipcRenderer.invoke('app:relaunch'),

  onData: (cb) => ipcRenderer.on('data:changed', (_e, d) => cb(d)),
  onSettings: (cb) => ipcRenderer.on('settings:changed', (_e, d) => cb(d)),
  onTick: (cb) => ipcRenderer.on('ui:tick', (_e, d) => cb(d)),
  onRefresh: (cb) => ipcRenderer.on('ui:refresh', (_e) => cb()),
  onGoto: (cb) => ipcRenderer.on('ui:goto', (_e, s) => cb(s))
});
