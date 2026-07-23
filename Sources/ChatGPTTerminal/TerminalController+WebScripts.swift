import Foundation

extension TerminalController {
    // MARK: Shared helpers

    static func jsString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
        return "\(encoded).at(0)"
    }

    static func userMessageHTML(text: String, attachmentCount: Int) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
        let badge = attachmentCount > 0 ? "<span class='image-badge'>▣ \(attachmentCount) Datei\(attachmentCount == 1 ? "" : "en")</span>" : ""
        return escaped + (escaped.isEmpty || badge.isEmpty ? "" : "<br>") + badge
    }

    static let promptExistsScript = """
    (() => !!(document.querySelector('#prompt-textarea') || document.querySelector('textarea') || document.querySelector('[contenteditable="true"]')))()
    """

    static let focusPromptScript = """
    (() => {
      const p = document.querySelector('#prompt-textarea') || document.querySelector('textarea') || document.querySelector('[contenteditable="true"]');
      if (!p) return false; p.focus(); return true;
    })()
    """

    // MARK: Conversation navigation

    static let previousChatURLScript = """
    (() => {
      const normalize = raw => {
        try {
          const url = new URL(raw, location.href);
          return url.pathname.replace(/\\/$/, '');
        } catch (_) { return ''; }
      };
      const currentPath = normalize(location.href);
      const candidates = [...document.querySelectorAll('a[href*="/c/"]')];
      const seen = new Set();
      const chats = candidates.filter(anchor => {
        const path = normalize(anchor.href);
        if (!path.includes('/c/') || seen.has(path)) return false;
        seen.add(path);
        return true;
      });
      let activeIndex = chats.findIndex(anchor => normalize(anchor.href) === currentPath);
      if (activeIndex < 0) {
        activeIndex = chats.findIndex(anchor => anchor.getAttribute('aria-current') === 'page' || anchor.dataset.active === 'true');
      }
      if (activeIndex >= 0 && activeIndex + 1 < chats.length) {
        const target = chats[activeIndex + 1];
        return {ok:true, url:new URL(target.href, location.href).href, title:(target.textContent || '').trim()};
      }
      if (activeIndex < 0) {
        const target = chats.find(anchor => normalize(anchor.href) !== currentPath);
        if (target) return {ok:true, url:new URL(target.href, location.href).href, title:(target.textContent || '').trim()};
      }
      const buttons = [...document.querySelectorAll('button')];
      const sidebarButton = buttons.find(button => {
        const description = ((button.getAttribute('aria-label') || '') + ' ' + (button.getAttribute('title') || '')).toLowerCase();
        return /open.*sidebar|sidebar.*open|seitenleiste.*öffnen|menü.*öffnen/.test(description);
      });
      if (sidebarButton) {
        sidebarButton.click();
        return {ok:false, retry:true};
      }
      return {ok:false, reason:'no-next-sidebar-chat'};
    })()
    """

    static let conversationImportScript = """
    (() => {
      if (!location.pathname.includes('/c/')) return {ready:false};
      const nodes = [...document.querySelectorAll('[data-message-author-role="user"], [data-message-author-role="assistant"]')];
      if (!nodes.length) return {ready:false};
      const signature = nodes.length + ':' + ((nodes.at(-1)?.textContent || '').length);
      if (window.__terminalImportSignature !== signature) {
        window.__terminalImportSignature = signature;
        window.__terminalImportStableSince = Date.now();
        return {ready:false};
      }
      if (Date.now() - (window.__terminalImportStableSince || 0) < 1200) return {ready:false};
      const cleanHTML = (node, role) => {
        const content = role === 'assistant'
          ? (node.querySelector('.markdown, [class*="markdown"]') || node)
          : (node.querySelector('[class*="whitespace-pre-wrap"], [data-message-content]') || node);
        const clone = content.cloneNode(true);
        clone.querySelectorAll('script, style, button, [contenteditable="true"]').forEach(element => element.remove());
        clone.querySelectorAll('*').forEach(element => {
          [...element.attributes].forEach(attribute => {
            if (/^on/i.test(attribute.name) || ['data-state','contenteditable'].includes(attribute.name)) element.removeAttribute(attribute.name);
          });
        });
        return clone.innerHTML.trim();
      };
      const messages = nodes.map(node => {
        const role = node.getAttribute('data-message-author-role');
        return {role, html:cleanHTML(node, role)};
      }).filter(message => message.html);
      if (!messages.length) return {ready:false};
      const latestAssistant = [...nodes].reverse().find(node => node.getAttribute('data-message-author-role') === 'assistant');
      const modelNode = latestAssistant?.matches?.('[data-message-model-slug], [data-model-slug], [data-model]')
        ? latestAssistant
        : latestAssistant?.querySelector?.('[data-message-model-slug], [data-model-slug], [data-model]');
      let model = modelNode?.getAttribute('data-message-model-slug') || modelNode?.getAttribute('data-model-slug') || modelNode?.getAttribute('data-model') || '';
      model = model.replace(/^gpt-(\\d+)-(\\d+)(?=-|$)/i, 'gpt-$1.$2');
      return {ready:true, messages, model};
    })()
    """

    // MARK: Clipboard

    static let copyLatestResponseScript = """
    (() => {
      const assistants = [...document.querySelectorAll('[data-message-author-role="assistant"]')];
      const node = assistants.at(-1) || [...document.querySelectorAll('article .markdown, article [class*="markdown"]')].at(-1);
      if (!node) return {found:false};
      const turn = node.closest('[data-testid^="conversation-turn-"]') || node.closest('article') || node.parentElement;
      const content = node.querySelector('.markdown, [class*="markdown"]') || node;
      const buttons = [...document.querySelectorAll('button')];
      const stopButton = document.querySelector('[data-testid="stop-button"], [data-testid*="stop" i]') || buttons.find(button => {
        const description = ((button.getAttribute('aria-label') || '') + ' ' +
          (button.getAttribute('title') || '') + ' ' +
          (button.getAttribute('data-testid') || '')).toLowerCase();
        return /stop|stopp|abbrechen|cancel|generierung.*beenden|antwort.*(?:stoppen|abbrechen|beenden)/.test(description);
      });
      const streamingMarker = turn?.querySelector?.('[aria-busy="true"], [data-streaming="true"], [class*="streaming" i]');
      const complete = !stopButton && !streamingMarker;

      const richClone = content.cloneNode(true);
      richClone.querySelectorAll('script, style, button').forEach(element => element.remove());
      richClone.querySelectorAll('*').forEach(element => {
        [...element.attributes].forEach(attribute => {
          if (/^on/i.test(attribute.name) || ['contenteditable','data-state'].includes(attribute.name)) element.removeAttribute(attribute.name);
        });
      });
      const source = richClone.cloneNode(true);
      const replaceMath = (element, display) => {
        const annotation = element.querySelector('annotation[encoding="application/x-tex"]');
        const latex = (annotation?.textContent || '').trim();
        if (!latex) return;
        const replacement = document.createElement('span');
        replacement.dataset.terminalLatex = `$$${latex}$$`;
        replacement.dataset.terminalDisplay = display ? 'true' : 'false';
        element.replaceWith(replacement);
      };
      [...source.querySelectorAll('.katex-display')].forEach(element => replaceMath(element, true));
      [...source.querySelectorAll('.katex')].forEach(element => replaceMath(element, false));

      const protectedBlocks = [];
      const protect = value => {
        const token = `TERMINALPROTECTED${protectedBlocks.length}TOKEN`;
        protectedBlocks.push(value);
        return token;
      };
      const children = element => [...element.childNodes].map(render).join('');
      const inline = element => children(element).trim();
      function render(current) {
        if (current.nodeType === Node.TEXT_NODE) return current.nodeValue || '';
        if (current.nodeType !== Node.ELEMENT_NODE) return '';
        if (current.dataset?.terminalLatex) return current.dataset.terminalLatex;
        const tag = current.tagName.toLowerCase();
        if (tag === 'br') return '\\n';
        if (tag === 'pre') {
          const code = current.querySelector('code') || current;
          const language = [...code.classList].map(name => name.match(/^language-(.+)$/)?.[1]).find(Boolean) || '';
          return '\\n\\n' + protect('```' + language + '\\n' + (code.textContent || '').replace(/\\n$/, '') + '\\n```') + '\\n\\n';
        }
        if (tag === 'code') return '`' + (current.textContent || '') + '`';
        if (tag === 'strong' || tag === 'b') return '**' + children(current) + '**';
        if (tag === 'em' || tag === 'i') return '*' + children(current) + '*';
        if (tag === 'del' || tag === 's') return '~~' + children(current) + '~~';
        if (tag === 'a') return '[' + children(current) + '](' + (current.getAttribute('href') || '') + ')';
        if (tag === 'img') return '![' + (current.getAttribute('alt') || '') + '](' + (current.getAttribute('src') || '') + ')';
        if (/^h[1-6]$/.test(tag)) return '#'.repeat(Number(tag[1])) + ' ' + inline(current) + '\\n\\n';
        if (tag === 'p') return children(current).trim() + '\\n\\n';
        if (tag === 'blockquote') {
          return children(current).trim().split('\\n').map(line => '> ' + line).join('\\n') + '\\n\\n';
        }
        if (tag === 'ul' || tag === 'ol') {
          const items = [...current.children].filter(child => child.tagName.toLowerCase() === 'li');
          return items.map((item,index) => {
            const copy = item.cloneNode(true);
            const nested = [...copy.children].filter(child => ['ul','ol'].includes(child.tagName.toLowerCase()));
            nested.forEach(child => child.remove());
            const prefix = tag === 'ol' ? `${index + 1}. ` : '- ';
            const main = render(copy).trim().replace(/\\n+/g, ' ');
            const below = nested.map(render).join('').trim();
            return prefix + main + (below ? '\\n' + below.split('\\n').map(line => '  ' + line).join('\\n') : '');
          }).join('\\n') + '\\n\\n';
        }
        if (tag === 'table') {
          const rows = [...current.querySelectorAll('tr')].map(row =>
            [...row.querySelectorAll(':scope > th, :scope > td')].map(cell => inline(cell).replace(/\\|/g, '\\|'))
          ).filter(row => row.length);
          if (!rows.length) return '';
          const width = Math.max(...rows.map(row => row.length));
          const normalized = rows.map(row => [...row, ...Array(width - row.length).fill('')]);
          const header = normalized[0];
          return '| ' + header.join(' | ') + ' |\\n| ' + header.map(() => '---').join(' | ') + ' |\\n' +
            normalized.slice(1).map(row => '| ' + row.join(' | ') + ' |').join('\\n') + '\\n\\n';
        }
        if (tag === 'hr') return '---\\n\\n';
        return children(current);
      }
      let markdown = render(source)
        .replace(/[ \\t]+\\n/g, '\\n')
        .replace(/\\n{3,}/g, '\\n\\n')
        .trim();
      protectedBlocks.forEach((value,index) => {
        markdown = markdown.replace(`TERMINALPROTECTED${index}TOKEN`, value);
      });

      const turnButtons = [...(turn?.querySelectorAll('button') || [])];
      const copyButton = turnButtons.find(button => {
        const description = ((button.getAttribute('aria-label') || '') + ' ' +
          (button.getAttribute('title') || '') + ' ' +
          (button.getAttribute('data-testid') || '')).toLowerCase();
        return /copy|kopieren/.test(description);
      });
      if (complete) copyButton?.click();
      return {found:true, complete, clicked:complete && !!copyButton, markdown, html:richClone.innerHTML};
    })()
    """

    // MARK: Attachments

    static func attachmentPresenceScript(fileNames: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: fileNames),
              let json = String(data: data, encoding: .utf8) else { return "false" }
        return """
        (() => {
          const names = \(json).map(name => name.toLowerCase());
          const prompt = document.querySelector('#prompt-textarea') || document.querySelector('textarea') || document.querySelector('[contenteditable="true"]');
          const scope = prompt?.closest('form')?.parentElement || prompt?.parentElement?.parentElement || document;
          const text = (scope.innerText || scope.textContent || '').toLowerCase();
          if (names.some(name => text.includes(name))) return true;
          return scope.querySelectorAll?.('[data-testid*="attachment"], [class*="attachment"], [aria-label$=".pdf" i]').length > 0;
        })()
        """
    }

    static func uploadAttachmentsScript(attachments: [PendingAttachment]) -> String {
        let payload = attachments.map { attachment in
            [
                "name": attachment.fileName,
                "type": attachment.mimeType,
                "base64": attachment.data.base64EncodedString()
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return "false" }
        return """
        (() => {
          const files = \(json);
          const inputs = [...document.querySelectorAll('input[type="file"]')];
          const input = inputs.find(i => /image|pdf|png|jpe?g|webp|heic/i.test(i.accept || '')) || inputs.at(-1);
          if (!input) return false;
          const transfer = new DataTransfer();
          for (const file of files) {
            const raw = atob(file.base64);
            const bytes = new Uint8Array(raw.length);
            for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
            transfer.items.add(new File([bytes], file.name, {type:file.type, lastModified:Date.now()}));
          }
          try {
            input.files = transfer.files;
            input.dispatchEvent(new Event('input', {bubbles:true}));
            input.dispatchEvent(new Event('change', {bubbles:true}));
            return true;
          } catch (_) {
            return false;
          }
        })()
        """
    }

    static let openNativeUploadScript = """
    (() => {
      const inputs = [...document.querySelectorAll('input[type="file"]')];
      const documentInput = inputs.find(i => {
        const accept = (i.accept || '').toLowerCase();
        return accept.includes('pdf') || accept.includes('application/') || (!accept.includes('image') && accept !== '');
      });
      if (documentInput) { documentInput.click(); return 'input'; }
      const buttons = [...document.querySelectorAll('button')];
      const add = document.querySelector('[data-testid="composer-plus-btn"], #composer-plus-btn') || buttons.find(b => /dateien und mehr|datei hinzufügen|add files|attach files|attachments|anhängen/i.test(
        (b.getAttribute('aria-label') || '') + ' ' + (b.innerText || '') + ' ' + (b.getAttribute('data-testid') || '')
      ));
      if (!add) return 'none';
      add.click();
      return 'menu';
    })()
    """

    static let clickNativeUploadMenuItemScript = """
    (() => {
      const visible = e => !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
      const inputs = [...document.querySelectorAll('input[type="file"]')];
      const documentInput = inputs.find(i => {
        const accept = (i.accept || '').toLowerCase();
        return accept.includes('pdf') || accept.includes('application/') || (!accept.includes('image') && accept !== '');
      });
      if (documentInput) { documentInput.click(); return true; }
      const options = [...document.querySelectorAll('[role="menuitem"], [role="option"], [data-radix-menu-content] button')].filter(visible);
      const item = options.find(e => {
        const text = ((e.innerText || '') + ' ' + (e.getAttribute('aria-label') || '')).toLowerCase();
        return /datei|file|computer|upload/.test(text);
      });
      if (!item) return false;
      item.click();
      return true;
    })()
    """

    // MARK: Submission and response tracking

    static func prepareMessageScript(text: String) -> String {
        """
        (() => {
          const text = \(jsString(text));
          const p = document.querySelector('#prompt-textarea') || document.querySelector('textarea') || document.querySelector('[contenteditable="true"]');
          if (!p) return false;
          p.focus();
          if (text) {
            if (p.tagName === 'TEXTAREA') {
              const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value')?.set;
              setter ? setter.call(p, text) : (p.value = text);
              p.dispatchEvent(new Event('input', {bubbles:true}));
            } else {
              document.execCommand('selectAll', false, null);
              document.execCommand('insertText', false, text);
              p.dispatchEvent(new InputEvent('input', {bubbles:true, inputType:'insertText', data:text}));
            }
          }
          return true;
        })()
        """
    }

    static let beginSubmissionMonitorScript = """
    (() => {
      window.__terminalSubmission = {
        baselineUsers: document.querySelectorAll('[data-message-author-role="user"]').length,
        baselineAssistants: document.querySelectorAll('[data-message-author-role="assistant"]').length,
        clicked: false,
        lastClick: 0
      };
      return true;
    })()
    """

    static let submissionAttemptScript = """
    (() => {
      const state = window.__terminalSubmission;
      if (!state) return {state:'waiting'};
      const userCount = document.querySelectorAll('[data-message-author-role="user"]').length;
      const assistantCount = document.querySelectorAll('[data-message-author-role="assistant"]').length;
      if (assistantCount > state.baselineAssistants) return {state:'response'};
      if (userCount > state.baselineUsers) return {state:'accepted'};

      const prompt = document.querySelector('#prompt-textarea') || document.querySelector('textarea') || document.querySelector('[contenteditable="true"]');
      const scope = prompt?.closest('form')?.parentElement || prompt?.parentElement?.parentElement || document;
      const scopeText = (scope.innerText || scope.textContent || '').toLowerCase();
      const progress = scope.querySelector?.('[role="progressbar"], [aria-busy="true"], progress');
      const uploading = !!progress || /uploading|wird hochgeladen|lädt hoch|datei wird verarbeitet|processing file/.test(scopeText);
      if (uploading) return {state:'uploading'};

      const buttons = [...document.querySelectorAll('button')];
      const send = document.querySelector('[data-testid="send-button"]') ||
        buttons.find(b => /send|senden|submit/i.test((b.getAttribute('aria-label') || '') + ' ' + (b.getAttribute('data-testid') || '')));
      const promptText = prompt ? ((prompt.value || prompt.innerText || prompt.textContent || '').trim()) : '';
      if (state.clicked && !promptText && (!send || send.disabled)) return {state:'accepted'};
      if (!send || send.disabled || send.getAttribute('aria-disabled') === 'true') return {state:'waiting'};

      const now = Date.now();
      if (now - state.lastClick < 1100) return {state:'waiting'};
      send.click();
      state.clicked = true;
      state.lastClick = now;
      return {state:'clicked'};
    })()
    """

    static let readinessScript = """
    (() => {
      if (window.__terminalReadyProbe) clearInterval(window.__terminalReadyProbe);
      window.__terminalReadyProbe = setInterval(() => {
        const p = document.querySelector('#prompt-textarea') || document.querySelector('textarea') || document.querySelector('[contenteditable="true"]');
        if (p) window.webkit.messageHandlers.terminalBridge.postMessage({type:'ready', url:location.href});
      }, 1500);
      return true;
    })()
    """

    static func responseObserverScript(responseID: String) -> String {
    """
    (() => {
      const responseID = \(jsString(responseID));
      if (window.__terminalResponseObserver) window.__terminalResponseObserver.disconnect();
      const initialRoleNodes = [...document.querySelectorAll('[data-message-author-role="assistant"]')];
      const initialMarkdownNodes = [...document.querySelectorAll('article .markdown, article [class*="markdown"]')];
      const initialNodes = new Set([...initialRoleNodes, ...initialMarkdownNodes]);
      let lastHTML = '';
      let stableTicks = 0;
      let lastChangeAt = Date.now();
      let lastStreaming = true;
      let finalSentAt = 0;
      let observedTurn = null;
      const extract = (force = false) => {
        const roleNodes = [...document.querySelectorAll('[data-message-author-role="assistant"]')];
        const markdownNodes = [...document.querySelectorAll('article .markdown, article [class*="markdown"]')];
        const newRoleNodes = roleNodes.filter(node => !initialNodes.has(node));
        const newMarkdownNodes = markdownNodes.filter(node => !initialNodes.has(node));
        const node = newRoleNodes.at(-1) || newMarkdownNodes.at(-1);
        if (!node) return;
        const buttons = [...document.querySelectorAll('button')];
        const stop = document.querySelector('[data-testid="stop-button"], [data-testid*="stop" i], button[aria-label*="Stop" i], button[aria-label*="Stopp" i]') || buttons.find(button => {
          const label = ((button.getAttribute('aria-label') || '') + ' ' + (button.getAttribute('title') || '') + ' ' + (button.getAttribute('data-testid') || '')).toLowerCase();
          return /stop|stopp|abbrechen|cancel|generierung.*beenden|antwort.*(?:stoppen|abbrechen|beenden)/.test(label);
        });
        const content = node.querySelector('.markdown, [class*="markdown"]') || node;
        const clone = content.cloneNode(true);
        clone.querySelectorAll('script, style, button').forEach(n => n.remove());
        clone.querySelectorAll('*').forEach(n => {
          [...n.attributes].forEach(a => {
            if (/^on/i.test(a.name) || ['contenteditable','data-state'].includes(a.name)) n.removeAttribute(a.name);
          });
        });
        const html = clone.innerHTML;
        if (!html.trim()) return;
        const turn = node.closest('article') || node.closest('[data-testid^="conversation-turn-"]') || node;
        observedTurn = turn;
        const streamingMarker = turn.querySelector?.('[aria-busy="true"], [data-streaming="true"], [class*="streaming" i]');
        const activelyGenerating = !!stop || !!streamingMarker;
        const modelElement = turn.matches?.('[data-message-model-slug], [data-model-slug], [data-model]') ? turn :
          turn.querySelector?.('[data-message-model-slug], [data-model-slug], [data-model]');
        let model = modelElement?.getAttribute('data-message-model-slug') ||
          modelElement?.getAttribute('data-model-slug') || modelElement?.getAttribute('data-model') || '';
        if (!model) {
          const markup = turn.outerHTML || '';
          const match = markup.match(/data-(?:message-)?model(?:-slug)?=["']([^"']+)["']/i);
          if (match) model = match[1];
        }
        model = model.replace(/^gpt-(\\d+)-(\\d+)(?=-|$)/i, 'gpt-$1.$2');
        const changed = html !== lastHTML;
        if (changed) {
          stableTicks = 0;
          lastChangeAt = Date.now();
          finalSentAt = 0;
        } else {
          stableTicks += 1;
        }
        lastHTML = html;

        // Copy/rating controls are ChatGPT's most reliable indication that a
        // turn has completed. If their markup changes, a conservative quiet
        // period prevents pauses during reasoning from truncating the answer.
        const actionButtons = [...(turn.querySelectorAll?.('button') || [])];
        const hasCompletionControls = !!turn.querySelector?.('[data-testid*="copy" i], [data-testid*="feedback" i]') || actionButtons.some(button => {
          const label = ((button.getAttribute('aria-label') || '') + ' ' + (button.getAttribute('data-testid') || '')).toLowerCase();
          return /copy|kopieren|good response|bad response|gute antwort|schlechte antwort/.test(label);
        });
        const quietFor = Date.now() - lastChangeAt;
        const streaming = activelyGenerating || (hasCompletionControls ? quietFor < 1800 : quietFor < 12000);
        if (force || changed || streaming !== lastStreaming || (!streaming && !finalSentAt)) {
          window.webkit.messageHandlers.terminalBridge.postMessage({type:'assistant', id:responseID, html, streaming, generating:activelyGenerating, changed, model});
        }
        lastStreaming = streaming;
        if (!streaming && !finalSentAt) finalSentAt = Date.now();

        // Stop only the periodic polling after an apparent end. The lightweight
        // MutationObserver remains alive until the next prompt, so even a very
        // long thinking pause cannot truncate a later continuation.
        if (!streaming && finalSentAt && Date.now() - finalSentAt > 3000 && window.__terminalResponseTimer) {
          clearInterval(window.__terminalResponseTimer);
          window.__terminalResponseTimer = null;
        }
      };
      const scheduleMutationExtract = mutations => {
        // The hidden ChatGPT page changes constantly. Once the active answer
        // is known, ignore unrelated mutations so the grace period stays
        // passive and cannot pressure the visible terminal UI.
        if (observedTurn && observedTurn.isConnected) {
          const relevant = mutations.some(mutation =>
            observedTurn.contains(mutation.target) ||
            [...mutation.addedNodes].some(node => node === observedTurn || (node.nodeType === 1 && node.contains?.(observedTurn)))
          );
          if (!relevant) return;
        }
        if (window.__terminalResponseMutationTimer) return;
        window.__terminalResponseMutationTimer = setTimeout(() => {
          window.__terminalResponseMutationTimer = null;
          extract(false);
        }, 250);
      };
      window.__terminalResponseObserver = new MutationObserver(scheduleMutationExtract);
      window.__terminalResponseExtract = extract;
      window.__terminalResponseObserver.observe(document.body, {subtree:true, childList:true, characterData:true});
      if (window.__terminalResponseTimer) clearInterval(window.__terminalResponseTimer);
      window.__terminalResponseTimer = setInterval(extract, 700);
      extract();
      return true;
    })()
    """
    }

    static let stopResponseObserverScript = """
    (() => {
      window.__terminalResponseObserver?.disconnect();
      window.__terminalResponseObserver = null;
      window.__terminalResponseExtract = null;
      if (window.__terminalResponseMutationTimer) clearTimeout(window.__terminalResponseMutationTimer);
      window.__terminalResponseMutationTimer = null;
      if (window.__terminalResponseTimer) clearInterval(window.__terminalResponseTimer);
      window.__terminalResponseTimer = null;
      return true;
    })()
    """

    static let stopCurrentOperationScript = """
    (() => {
      window.__terminalSubmission = null;
      window.__terminalResponseObserver?.disconnect();
      window.__terminalResponseObserver = null;
      window.__terminalResponseExtract = null;
      if (window.__terminalResponseMutationTimer) clearTimeout(window.__terminalResponseMutationTimer);
      window.__terminalResponseMutationTimer = null;
      if (window.__terminalResponseTimer) clearInterval(window.__terminalResponseTimer);
      window.__terminalResponseTimer = null;

      const buttons = [...document.querySelectorAll('button')];
      const stop = document.querySelector('[data-testid="stop-button"]') || buttons.find(b =>
        /stop|stopp|generierung beenden/i.test((b.getAttribute('aria-label') || '') + ' ' + (b.getAttribute('data-testid') || ''))
      );
      stop?.click();

      const prompt = document.querySelector('#prompt-textarea') || document.querySelector('textarea') || document.querySelector('[contenteditable="true"]');
      const scope = prompt?.closest('form')?.parentElement || prompt?.parentElement?.parentElement;
      [...(scope?.querySelectorAll('button') || [])].forEach(button => {
        const label = ((button.getAttribute('aria-label') || '') + ' ' + (button.getAttribute('data-testid') || '')).toLowerCase();
        if (/(remove|entfernen).*(file|datei|attachment|anhang|upload)|(file|datei|attachment|anhang|upload).*(remove|entfernen)/.test(label)) button.click();
      });

      if (prompt) {
        if (prompt.tagName === 'TEXTAREA') prompt.value = '';
        else prompt.textContent = '';
        prompt.dispatchEvent(new Event('input', {bubbles:true}));
      }
      return true;
    })()
    """

    // MARK: Model selection

    static func modelSelectionScript(choice: String) -> String {
        """
        (() => {
          const wanted = \(jsString(choice)).toLowerCase();
          const visible = e => !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
          const buttons = [...document.querySelectorAll('button')].filter(visible);
          const trigger = buttons.find(b => /model|modell|chatgpt|auto|instant|thinking|pro/i.test((b.innerText || '') + ' ' + (b.getAttribute('aria-label') || '')));
          if (!trigger) return false;
          trigger.click();
          setTimeout(() => {
            const options = [...document.querySelectorAll('[role="menuitem"], [role="option"], button')].filter(visible);
            const option = options.find(e => (e.innerText || '').toLowerCase().includes(wanted));
            if (option) option.click();
          }, 500);
          return true;
        })()
        """
    }

    // MARK: Terminal document

    static let terminalHTML = """
    <!doctype html><html><head><meta charset="utf-8">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
    <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
    <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js"></script>
    <style>
      :root { color-scheme: dark; }
      * { box-sizing: border-box; }
      html, body { margin:0; min-height:100%; background:#0e110f; color:#e8eadf; overflow-anchor:none; }
      body { padding:18px 20px 34px; font:14px/1.55 ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; }
      #empty { color:#758078; padding-top:4px; }
      .message { margin:0 0 22px; }
      .label { color:#b8eb60; font-weight:700; margin-bottom:5px; }
      .user { display:grid; grid-template-columns:max-content minmax(0,1fr); column-gap:10px; align-items:baseline; }
      .user .label { margin:0; }
      .user .body { min-width:0; }
      .assistant .label { color:#69d5d0; }
      .body { overflow-wrap:anywhere; }
      .assistant .body { font-family:ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; font-size:14px; line-height:1.55; }
      .assistant .body :not(.katex):not(.katex *) { font-family:inherit; }
      .assistant .body code, .assistant .body pre { font-family:inherit; }
      p { margin:.45em 0 .85em; } h1,h2,h3 { color:#f0f3e8; margin:1.15em 0 .45em; line-height:1.25; }
      h1 { font-size:1.38em; } h2 { font-size:1.22em; } h3 { font-size:1.08em; }
      pre { background:#171c19; border:1px solid #303a33; border-radius:7px; padding:12px; overflow:auto; white-space:pre; }
      code { color:#eadf9b; background:#171c19; padding:.12em .3em; border-radius:4px; }
      pre code { color:#e8eadf; background:transparent; padding:0; }
      blockquote { margin:.8em 0; border-left:3px solid #7a9d45; padding:.2em 0 .2em 12px; color:#c5ccbf; }
      table { border-collapse:collapse; width:100%; margin:.8em 0; } th,td { border:1px solid #39423b; padding:7px 9px; text-align:left; }
      a { color:#79c8ff; } img { max-width:100%; border-radius:7px; }
      .image-badge { display:inline-block; color:#d2e99d; border:1px solid #627a3d; border-radius:5px; padding:2px 7px; margin-top:4px; }
      .transfer-status { color:#d9bd67; margin:-12px 0 20px; }
      .boot { margin:0 0 24px; color:#aeb7ad; }
      .boot-command { color:#e8eadf; }
      .boot-prompt { color:#b8eb60; font-weight:700; }
      .boot-step { color:#758078; }
      .boot-ok { color:#69d5d0; }
      .boot-model { color:#eadf9b; font-weight:700; }
      .katex-display { overflow-x:auto; overflow-y:hidden; padding:.35em 0; }
      mark.terminal-search-hit { color:inherit; background:#7c6d2b; border-radius:3px; padding:0 .08em; }
      mark.terminal-search-hit.current { background:#c4a83c; color:#11140f; outline:1px solid #eadf9b; }
      html[data-theme="blue"], html[data-theme="blue"] body { background:#0e110f; color:#e7ebf4; }
      html[data-theme="blue"] #empty, html[data-theme="blue"] .boot-step { color:#7582a3; }
      html[data-theme="blue"] .label, html[data-theme="blue"] .boot-prompt { color:#93afe5; }
      html[data-theme="blue"] .assistant .label, html[data-theme="blue"] .boot-ok { color:#8abfd2; }
      html[data-theme="blue"] h1, html[data-theme="blue"] h2, html[data-theme="blue"] h3 { color:#f0f3fa; }
      html[data-theme="blue"] pre, html[data-theme="blue"] code { background:#0b1838; }
      html[data-theme="blue"] pre { border-color:#25365f; }
      html[data-theme="blue"] pre code { background:transparent; color:#e7ebf4; }
      html[data-theme="blue"] code, html[data-theme="blue"] .boot-model { color:#b7c8e8; }
      html[data-theme="blue"] blockquote { border-left-color:#5877b7; color:#c4ccdd; }
      html[data-theme="blue"] th, html[data-theme="blue"] td { border-color:#2b3b65; }
      html[data-theme="blue"] a { color:#80b8e8; }
      html[data-theme="blue"] .image-badge { color:#c0cee8; border-color:#4b6191; }
      html[data-theme="blue"] .transfer-status { color:#b7c5df; }
      html[data-theme="blue"] mark.terminal-search-hit { background:#334b82; }
      html[data-theme="blue"] mark.terminal-search-hit.current { background:#86a8ea; color:#07102d; outline-color:#c9d8f5; }
    </style></head><body><div id="empty"></div><div id="log"></div>
    <script>
      const log = document.getElementById('log'), empty = document.getElementById('empty');
      let persistenceEnabled = false, snapshotTimer = null;
      const queueSnapshot = () => {
        if (!persistenceEnabled) return;
        if (snapshotTimer) clearTimeout(snapshotTimer);
        snapshotTimer = setTimeout(() => {
          snapshotTimer = null;
          const snapshot=log.cloneNode(true);
          snapshot.querySelectorAll('mark.terminal-search-hit').forEach(mark=>mark.replaceWith(document.createTextNode(mark.textContent || '')));
          snapshot.normalize();
          window.webkit.messageHandlers.terminalStateBridge.postMessage({
            html:snapshot.innerHTML,
            model:window.terminal?.currentModel || 'detecting …'
          });
        },350);
      };
      const nearBottom = () => document.documentElement.scrollHeight - window.innerHeight - window.scrollY <= 24;
      let followTail = true;
      window.addEventListener('scroll', () => { followTail = nearBottom(); }, {passive:true});
      const scrollBottom = (force=false) => {
        if (!force && !followTail) return;
        followTail = true;
        window.scrollTo({top:document.documentElement.scrollHeight, behavior:'auto'});
      };
      const preserveReadingPosition = update => {
        const wasFollowing = followTail;
        const previousY = window.scrollY;
        update();
        if (wasFollowing) scrollBottom(true);
        else {
          followTail = false;
          window.scrollTo({top:previousY, behavior:'auto'});
        }
      };
      const typesetMath = root => {
        if (typeof renderMathInElement !== 'function') return true;
        const slash=String.fromCharCode(92);
        try {
          renderMathInElement(root, {
            delimiters:[
              {left:'$$',right:'$$',display:true},
              {left:slash+'[',right:slash+']',display:true},
              {left:slash+'(',right:slash+')',display:false},
              {left:'$',right:'$',display:false}
            ],
            ignoredClasses:['katex','katex-display','katex-html','katex-mathml'],
            throwOnError:false,
            strict:'ignore'
          });
        } catch (_) { return false; }
        return !root.querySelector('.katex-error');
      };
      const searchState={query:'',marks:[],index:-1};
      const clearSearchHighlights=()=>{
        document.querySelectorAll('mark.terminal-search-hit').forEach(mark=>mark.replaceWith(document.createTextNode(mark.textContent || '')));
        log.normalize();
        searchState.marks=[];
        searchState.index=-1;
      };
      const searchPayload=()=>({count:searchState.marks.length,index:searchState.index});
      const selectSearchHit=index=>{
        if(!searchState.marks.length){ searchState.index=-1; return searchPayload(); }
        searchState.index=((index % searchState.marks.length)+searchState.marks.length)%searchState.marks.length;
        searchState.marks.forEach((mark,i)=>mark.classList.toggle('current',i===searchState.index));
        const target=searchState.marks[searchState.index];
        followTail=false;
        target.scrollIntoView({block:'center',inline:'nearest',behavior:'auto'});
        return searchPayload();
      };
      window.terminal = {
        currentModel:'detecting …',
        setTheme(theme){ document.documentElement.dataset.theme=theme === 'blue' ? 'blue' : 'dark'; },
        restore(html,model){
          this.currentModel=model || this.currentModel;
          log.innerHTML=html || '';
          empty.style.display=log.children.length ? 'none' : 'block';
          followTail=true;
          setTimeout(()=>scrollBottom(true),0);
        },
        enablePersistence(){ persistenceEnabled=true; queueSnapshot(); },
        clear(){ searchState.query=''; searchState.marks=[]; searchState.index=-1; followTail=true; log.innerHTML=''; empty.style.display='block'; window.scrollTo({top:0,behavior:'auto'}); },
        jumpToBottom(){ followTail=true; scrollBottom(true); },
        clearSearch(){ searchState.query=''; clearSearchHighlights(); return searchPayload(); },
        search(query){
          clearSearchHighlights();
          searchState.query=(query || '').trim();
          if(!searchState.query) return searchPayload();
          const needle=searchState.query.toLocaleLowerCase();
          const walker=document.createTreeWalker(log,NodeFilter.SHOW_TEXT,{acceptNode(node){
            const parent=node.parentElement;
            if(!parent || !node.nodeValue || !parent.closest('.body,.boot')) return NodeFilter.FILTER_REJECT;
            if(parent.closest('.label,.katex,script,style,mark.terminal-search-hit')) return NodeFilter.FILTER_REJECT;
            return node.nodeValue.toLocaleLowerCase().includes(needle) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
          }});
          const nodes=[];
          while(walker.nextNode()) nodes.push(walker.currentNode);
          nodes.forEach(node=>{
            const value=node.nodeValue || '';
            const lower=value.toLocaleLowerCase();
            let cursor=0,match=lower.indexOf(needle);
            if(match<0) return;
            const fragment=document.createDocumentFragment();
            while(match>=0){
              if(match>cursor) fragment.appendChild(document.createTextNode(value.slice(cursor,match)));
              const mark=document.createElement('mark');
              mark.className='terminal-search-hit';
              mark.textContent=value.slice(match,match+searchState.query.length);
              fragment.appendChild(mark);
              searchState.marks.push(mark);
              cursor=match+searchState.query.length;
              match=lower.indexOf(needle,cursor);
            }
            if(cursor<value.length) fragment.appendChild(document.createTextNode(value.slice(cursor)));
            node.replaceWith(fragment);
          });
          return searchState.marks.length ? selectSearchHit(0) : searchPayload();
        },
        searchStep(delta){ return selectSearchHit(searchState.index+(delta < 0 ? -1 : 1)); },
        boot(model){
          this.currentModel=model || this.currentModel;
          empty.style.display='none';
          const e=document.createElement('section'); e.className='boot'; e.dataset.boot='true';
          e.innerHTML='<div class="boot-command"><span class="boot-prompt">$</span> pip \(terminalAddress)</div><div class="boot-lines"></div>';
          log.appendChild(e); const lines=e.querySelector('.boot-lines'); scrollBottom();
          setTimeout(()=>{ lines.insertAdjacentHTML('beforeend','<div class="boot-step">[1/3] loading authenticated session …</div>'); scrollBottom(); },160);
          setTimeout(()=>{ lines.insertAdjacentHTML('beforeend','<div class="boot-step">[2/3] mounting multimodal transport …</div>'); scrollBottom(); },360);
          setTimeout(()=>{ lines.insertAdjacentHTML('beforeend','<div class="boot-ok">[3/3] terminal ready ✓</div>'); scrollBottom(); },590);
          setTimeout(()=>{ const row=document.createElement('div'); row.innerHTML='current model: <span class="boot-model"></span>'; row.querySelector('.boot-model').textContent=terminal.currentModel; lines.appendChild(row); scrollBottom(); },780);
        },
        setModel(model){ this.currentModel=model; const target=[...document.querySelectorAll('.boot-model')].at(-1); if(target) target.textContent=model; },
        addUser(html){ empty.style.display='none'; const e=document.createElement('section'); e.className='message user'; e.innerHTML='<div class="label">INPUT &gt;</div><div class="body">'+html+'</div>'; log.appendChild(e); scrollBottom(); },
        setTransferStatus(text){ let e=document.querySelector('.transfer-status'); if(!text){ e?.remove(); return; } if(!e){ e=document.createElement('div'); e.className='transfer-status'; log.appendChild(e); } e.textContent=text; scrollBottom(); },
        beginAssistant(id){ empty.style.display='none'; const e=document.createElement('section'); e.className='message assistant'; e.dataset.id=id; e.innerHTML='<div class="label">CHATGPT &gt;</div><div class="body"></div>'; log.appendChild(e); scrollBottom(); },
        beginThinking(id){ let e=[...document.querySelectorAll('.assistant')].find(x=>x.dataset.id===id); if(!e){ this.beginAssistant(id); e=[...document.querySelectorAll('.assistant')].at(-1); } preserveReadingPosition(()=>{ e.querySelector('.body').textContent='Denke nach …'; }); },
        updateAssistant(id,html,streaming){
          let e=[...document.querySelectorAll('.assistant')].find(x=>x.dataset.id===id);
          if(!e){ this.beginAssistant(id); e=[...document.querySelectorAll('.assistant')].at(-1); }
          const body=e.querySelector('.body');
          const staged=document.createElement('div');
          staged.innerHTML=html;
          if(!typesetMath(staged)) return false;
          preserveReadingPosition(()=>{
            body.replaceChildren(...staged.childNodes);
            body.dataset.renderStable='true';
          });
          return true;
        }
      };
      new MutationObserver(queueSnapshot).observe(log,{subtree:true,childList:true,characterData:true,attributes:true});
      terminal.boot('detecting …');
    </script></body></html>
    """
}
