// Popup: triggers the export in the active tab's content script, injecting it
// first if the page was loaded before the extension was installed or enabled.
'use strict';

const EXPORT_MESSAGE = { type: 'EXPORT_SCORE_PDF' };
const SCORE_PAGE_PATTERN = /^https:\/\/musescore\.com\//;
const NO_RECEIVER_PATTERN = /Receiving end does not exist|Could not establish connection/i;

const button = document.querySelector('#export');
const status = document.querySelector('#status');

button.addEventListener('click', exportActiveTab);

async function exportActiveTab() {
  button.disabled = true;
  setStatus('Finding and loading score pages…');

  try {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (!tab?.id || !SCORE_PAGE_PATTERN.test(tab.url || '')) {
      throw new Error('Open a score on musescore.com first.');
    }

    const response = await sendExportMessage(tab.id);
    if (!response?.ok) throw new Error(response?.error || 'Export failed.');
    setStatus(`Downloaded ${response.pages} page${response.pages === 1 ? '' : 's'} as one PDF.`, 'success');
  } catch (error) {
    setStatus(error.message || String(error), 'error');
  } finally {
    button.disabled = false;
  }
}

async function sendExportMessage(tabId) {
  try {
    return await chrome.tabs.sendMessage(tabId, EXPORT_MESSAGE);
  } catch (error) {
    if (!NO_RECEIVER_PATTERN.test(error.message || '')) throw error;

    setStatus('Connecting to the score page…');
    await chrome.scripting.executeScript({ target: { tabId }, files: ['content.js'] });
    return chrome.tabs.sendMessage(tabId, EXPORT_MESSAGE);
  }
}

function setStatus(message, kind = '') {
  status.textContent = message;
  status.dataset.kind = kind;
}
