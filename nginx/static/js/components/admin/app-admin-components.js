// Jump Server - Admin-only Web Components
// Contains admin actions wrappers and modal; load this only for admin users

(function(){
    function createTemplate(html) {
        const tpl = document.createElement('template');
        tpl.innerHTML = html.trim();
        return tpl;
    }

    async function whenApiClientReady(maxWaitMs = 10000) {
        const started = Date.now();
        while (!window.apiClient) {
            if (Date.now() - started > maxWaitMs) throw new Error('apiClient not ready');
            await new Promise(r => setTimeout(r, 50));
        }
    }

    // Admin modal (moved from public components)
    class AppServiceModal extends HTMLElement {
        constructor() {
            super();
            this.attachShadow({ mode: 'open' });
            this._data = null; // existing service or null
            this._type = 'http';
            this._rootTpl = createTemplate(`
                <style>
                    :host { position: fixed; inset: 0; display:none; align-items:center; justify-content:center; background: rgba(0,0,0,.3); z-index: 9999; }
                    :host(.open) { display:flex; }
                    .modal { background: var(--clr-bg-highlight); border-radius: var(--radius-lg); width: min(640px, 95vw); max-height: 90vh; box-shadow: var(--shadow-xl); border:1px solid var(--clr-border-muted); display: flex; flex-direction: column; }
                    .header { display:flex; align-items:center; justify-content:space-between; padding:16px 20px; border-bottom:1px solid var(--clr-border); }
                    .header .title { font-size: 16px; font-weight: 600; }
                    .body { padding: 20px; overflow-y: auto; flex: 1; }
                    .section { margin-bottom: 20px; }
                    .section:last-child { margin-bottom: 0; }
                    .section-title { font-weight: 600; font-size: 14px; margin-bottom: 8px; color: var(--clr-text-high); }
                    .section-card { background: var(--clr-bg-dark); border:1px solid var(--clr-border-muted); border-radius: var(--radius-md); padding: 12px; }
                    .row { margin: 8px 0; display:flex; flex-direction:column; gap:4px; }
                    .row:first-child { margin-top: 0; }
                    .row:last-child { margin-bottom: 0; }
                    label { font-size:13px; color: var(--clr-text-muted); font-weight: 500; }
                    input[type="text"], input[type="url"], textarea, select { border:1px solid var(--clr-border); border-radius: var(--radius-md); padding:8px 10px; font-size:13px; background: var(--clr-bg-highlight); color: var(--clr-text-high); }
                    input[type="text"]:focus, input[type="url"]:focus, textarea:focus, select:focus { outline: 2px solid var(--clr-primary-base); outline-offset: 0; }
                    .footer { padding: 12px 20px; display:flex; gap:.5rem; justify-content:flex-end; border-top:1px solid var(--clr-border); }
                    .btn { border:1px solid var(--clr-border); background: var(--clr-bg-highlight); padding:8px 12px; border-radius: var(--radius-md); cursor:pointer; color: var(--clr-text-high); font-size:13px; display: inline-flex; align-items: center; gap: 6px; transition: all 0.15s ease; }
                    .btn:hover { background: var(--clr-bg-dark); }
                    .btn.primary { background: var(--clr-primary-base); color:var(--clr-highlight); border-color: var(--clr-primary-base); }
                    .btn.primary:hover { background: var(--clr-primary-light); }
                    .btn.secondary { background: var(--clr-bg-dark); color: var(--clr-text-high); }
                    .btn.success { background: var(--clr-success); color:#fff; border-color: var(--clr-success); }
                    .btn.success:hover { opacity: 0.9; }
                    .btn.danger { background: var(--clr-danger); color:#fff; border-color: var(--clr-danger); }
                    .btn.danger:hover { opacity: 0.9; }
                    .btn-icon { display: inline-block; width: 14px; height: 14px; background-color: currentColor; -webkit-mask-size: contain; -webkit-mask-repeat: no-repeat; -webkit-mask-position: center; mask-size: contain; mask-repeat: no-repeat; mask-position: center; }
                    .icon-plus { -webkit-mask-image: url(/static/icons/plus.svg); mask-image: url(/static/icons/plus.svg); }
                    .icon-trash { -webkit-mask-image: url(/static/icons/trash.svg); mask-image: url(/static/icons/trash.svg); }
                    .icon-check { -webkit-mask-image: url(/static/icons/check.svg); mask-image: url(/static/icons/check.svg); }
                    .icon-close { -webkit-mask-image: url(/static/icons/close.svg); mask-image: url(/static/icons/close.svg); }
                    .perm-section .data-table { width:100%; table-layout: fixed; border-collapse: collapse; }
                    .perm-section .data-table th, .perm-section .data-table td { padding:8px; text-align: left; }
                    .perm-section .data-table th { background: var(--clr-bg-dark); font-size: 12px; font-weight: 600; color: var(--clr-text-muted); }
                    .perm-section .data-table th:nth-child(1), .perm-section .data-table td:nth-child(1) { width: 22%; }
                    .perm-section .data-table th:nth-child(2), .perm-section .data-table td:nth-child(2) { width: auto; }
                    .perm-section .data-table th:nth-child(3), .perm-section .data-table td:nth-child(3) { width: 120px; }
                    .perm-section td.actions { text-align:right; }
                    .perm-section td.actions > .actions { display:inline-flex; gap:.25rem; justify-content:flex-end; width:100%; }
                    .perm-section input.perm-role { width:100%; }
                    .perm-section .code { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace; font-size:12px; }
                </style>
                <div class="modal">
                    <div class="header">
                        <div class="title">Service</div>
                        <button class="btn close" title="Close">×</button>
                    </div>
                    <div class="body">
                        <div class="section">
                            <div class="section-title">Basic Information</div>
                            <div class="section-card">
                                <div class="row"><label>Service Type</label><select class="type"><option value="http">HTTP/Web Service</option><option value="ssh">SSH Service</option></select></div>
                                <div class="row"><label>Service ID</label><input class="id" type="text" placeholder="my-service"></div>
                                <div class="row"><label>Display Name</label><input class="name" type="text" placeholder="Pretty name"></div>
                                <div class="row"><label>Description</label><textarea class="desc" rows="3" placeholder="Brief description of this service"></textarea></div>
                                <div class="row"><label><input type="checkbox" class="enabled"> Service is enabled</label></div>
                            </div>
                        </div>
                        
                        <div class="section">
                            <div class="section-title">Target Configuration</div>
                            <div class="section-card">
                                <div class="row for-http"><label>Target URL</label><input class="http-url" type="url" placeholder="http://host:port/path"></div>
                                <div class="row for-ssh" style="display:none;"><label>Target (host:port)</label><input class="ssh-target" type="text" placeholder="host:22"></div>
                            </div>
                        </div>
                        
                        <div class="section">
                            <div class="section-title">Access Control</div>
                            <div class="section-card">
                                <div class="perm-section">
                                    <datalist id="perm-roles"></datalist>
                                    <table class="data-table">
                                        <thead><tr><th>Type</th><th>Role</th><th>Actions</th></tr></thead>
                                        <tbody id="perm-tbody"></tbody>
                                    </table>
                                </div>
                            </div>
                        </div>
                    </div>
                    <div class="footer">
                        <button class="btn cancel" title="Cancel">
                            <span class="btn-icon icon-close"></span>
                            <span>Cancel</span>
                        </button>
                        <button class="btn primary save" title="Save">
                            <span class="btn-icon icon-check"></span>
                            <span>Save</span>
                        </button>
                    </div>
                </div>
            `);
        }

        connectedCallback() { this.render(); this._wire(); }

        open(data = null, type = 'http') {
            this._data = data;
            this._type = type || 'http';
            this.render();
            this.classList.add('open');
            this._bindEsc();
        }

        close() { this.classList.remove('open'); this._unbindEsc(); }

        render() {
            const root = this.shadowRoot;
            if (!root.firstChild) root.appendChild(this._rootTpl.content.cloneNode(true));
            const isEdit = !!this._data;
            const title = root.querySelector('.title');
            if (title) title.textContent = isEdit ? 'Edit Service' : 'Add Service';
            const typeSel = root.querySelector('select.type');
            const httpRow = root.querySelector('.for-http');
            const sshRow = root.querySelector('.for-ssh');
            const idEl = root.querySelector('input.id');
            const nameEl = root.querySelector('input.name');
            const descEl = root.querySelector('textarea.desc');
            const enEl = root.querySelector('input.enabled');
            const httpUrlEl = root.querySelector('input.http-url');
            const sshTargetEl = root.querySelector('input.ssh-target');
            if (typeSel) {
                typeSel.value = this._type;
                // Disable changing type when editing an existing service
                typeSel.disabled = isEdit;
            }
            if (this._type === 'http') { httpRow.style.display = ''; sshRow.style.display = 'none'; }
            else { httpRow.style.display = 'none'; sshRow.style.display = ''; }
            const d = this._data || {};
            idEl.value = d.id || '';
            nameEl.value = d.name || '';
            descEl.value = d.description || '';
            enEl.checked = !!d.enabled;
            httpUrlEl.value = d.url || (d.protocol && d.host ? `${d.protocol}://${d.host}:${d.port||80}${d.path||'/'}` : '');
            sshTargetEl.value = d.host ? `${d.host}:${d.port||22}` : '';

            // initialize permissions editor
            this._initPermissions(d.permissions || []);
        }

        _wire() {
            const root = this.shadowRoot;
            const typeSel = root.querySelector('select.type');
            const httpRow = root.querySelector('.for-http');
            const sshRow = root.querySelector('.for-ssh');
            typeSel && typeSel.addEventListener('change', () => {
                this._type = typeSel.value;
                if (this._type === 'http') { httpRow.style.display = ''; sshRow.style.display = 'none'; }
                else { httpRow.style.display = 'none'; sshRow.style.display = ''; }
            });
            const onCancel = () => this.close();
            const cancelBtn = root.querySelector('.btn.cancel');
            const closeBtn = root.querySelector('.btn.close');
            cancelBtn && cancelBtn.addEventListener('click', onCancel);
            closeBtn && closeBtn.addEventListener('click', onCancel);
            const saveBtn = root.querySelector('.btn.save');
            saveBtn && saveBtn.addEventListener('click', () => {
                const id = root.querySelector('input.id').value.trim();
                const name = root.querySelector('input.name').value.trim();
                const description = root.querySelector('textarea.desc').value.trim();
                const enabled = root.querySelector('input.enabled').checked;
                let payload = { id, name, description, enabled };
                if (this._type === 'http') {
                    const url = root.querySelector('input.http-url').value.trim();
                    try {
                        const parsed = new URL(url);
                        payload = { ...payload, type: 'http', url, protocol: parsed.protocol.replace(':',''), host: parsed.hostname, port: parseInt(parsed.port)|| (parsed.protocol==='https:'?443:80), path: parsed.pathname || '/' };
                    } catch (_) {
                        payload = { ...payload, type: 'http', url };
                    }
                } else {
                    const target = root.querySelector('input.ssh-target').value.trim();
                    const [host, portStr] = target.split(':');
                    payload = { ...payload, type: 'ssh', host, port: parseInt(portStr)||22 };
                }
                payload.permissions = this._collectPermissions();
                const validationError = this._validatePayload(payload);
                if (validationError) {
                    window.notifications && notifications.error(validationError);
                    return;
                }
                this.dispatchEvent(new CustomEvent('service-save', { bubbles: true, composed: true, detail: { payload, original: this._data } }));
                this.close();
            });
        }

        _bindEsc(){
            if (this._escBound) return;
            this._escHandler = (e)=>{ if (e && (e.key === 'Escape' || e.key === 'Esc')) { e.preventDefault(); this.close(); } };
            window.addEventListener('keydown', this._escHandler, true);
            this._escBound = true;
        }

        _unbindEsc(){
            if (!this._escBound) return;
            window.removeEventListener('keydown', this._escHandler, true);
            this._escBound = false;
            this._escHandler = null;
        }

        async _initPermissions(initial) {
            const r = this.shadowRoot;
            const listEl = r.getElementById('perm-roles');
            const tbody = r.getElementById('perm-tbody');
            if (!listEl || !tbody) return;
            // Reset table to avoid duplicate rows when re-opening or re-rendering
            tbody.innerHTML = '';
            // fetch roles suggestions
            let options = [];
            try {
                if (window.apiClient && window.apiClient.roles) {
                    const resp = await window.apiClient.roles.list();
                    const roles = (resp && resp.data && Array.isArray(resp.data.roles)) ? resp.data.roles : [];
                    options = roles.map(r => String(r.id || r.name)).sort();
                }
            } catch (_) { /* ignore */ }
            if (!options.length) options = ['jumpserver:admin','jumpserver:audit','jumpserver:user'];
            listEl.innerHTML = options.map(v => `<option value="${String(v).replace(/&/g,'&amp;').replace(/"/g,'&quot;')}"></option>`).join('');

            const sanitizeRole = (val) => {
                const v = String(val || '').trim();
                // allow letters, digits, colon, dash, underscore, dot
                const cleaned = v.replace(/[^A-Za-z0-9:_\-\.]/g, '');
                return cleaned;
            };

            const ensurePlaceholderAtBottom = () => {
                const ph = tbody.querySelector('tr.perm-row.placeholder');
                if (ph && ph !== tbody.lastElementChild) {
                    tbody.appendChild(ph);
                }
            };

            const renderSavedRow = (p) => {
                const type = (p && p.type) === 'deny' ? 'deny' : 'allow';
                const role = sanitizeRole(p && p.role ? p.role : '');
                if (!role) return;
                const tr = document.createElement('tr');
                tr.className = 'perm-row saved';
                tr.setAttribute('data-type', type);
                tr.setAttribute('data-role', role);
                tr.innerHTML = `<td>${type}</td>
                                <td class="code">${role.replace(/&/g,'&amp;')}</td>
                                <td class="actions"><div class="actions">
                                    <button type="button" class="btn danger perm-delete" title="Delete">
                                        <span class="btn-icon icon-trash"></span>
                                    </button>
                                </div></td>`;
                const placeholder = tbody.querySelector('tr.perm-row.placeholder');
                if (placeholder) {
                    tbody.insertBefore(tr, placeholder);
                } else {
                    tbody.appendChild(tr);
                }
                ensurePlaceholderAtBottom();
            };

            const renderPlaceholderRow = () => {
                // Ensure only one placeholder exists
                const existing = tbody.querySelector('tr.perm-row.placeholder');
                if (existing) { ensurePlaceholderAtBottom(); return existing; }
                const tr = document.createElement('tr');
                tr.className = 'perm-row placeholder';
                tr.innerHTML = `<td><select class="perm-type"><option value="allow">allow</option><option value="deny">deny</option></select></td>
                                <td><input type="text" class="perm-role" list="perm-roles" placeholder="role (e.g., jumpserver:user)" /></td>
                                <td class="actions"><div class="actions">
                                    <button type="button" class="btn success perm-save" title="Add">
                                        <span class="btn-icon icon-plus"></span>
                                    </button>
                                </div></td>`;
                tbody.appendChild(tr);
                ensurePlaceholderAtBottom();
                return tr;
            };

            (Array.isArray(initial) ? initial : []).forEach(renderSavedRow);
            renderPlaceholderRow();
            ensurePlaceholderAtBottom();

            tbody.onclick = (e) => {
                const saveBtn = e.target && e.target.closest('.perm-save');
                const delBtn = e.target && e.target.closest('.perm-delete');
                if (saveBtn) {
                    const row = saveBtn.closest('tr.placeholder');
                    if (!row) return;
                    const type = row.querySelector('.perm-type')?.value === 'deny' ? 'deny' : 'allow';
                    const roleInput = row.querySelector('.perm-role');
                    const rawRole = roleInput ? roleInput.value : '';
                    const role = sanitizeRole(rawRole);
                    if (!role) { window.notifications && notifications.error('Role is required'); return; }
                    // duplicate check
                    const exists = !!tbody.querySelector(`tr.saved[data-type="${type}"][data-role="${role}"]`);
                    if (exists) { window.notifications && notifications.error('Rule already exists'); return; }
                    renderSavedRow({ type, role });
                    // clear inputs
                    roleInput && (roleInput.value = '');
                    const sel = row.querySelector('.perm-type');
                    sel && (sel.value = 'allow');
                    ensurePlaceholderAtBottom();
                    return;
                }
                if (delBtn) {
                    const row = delBtn.closest('tr.saved');
                    row && row.remove();
                    // ensure a placeholder exists for further additions
                    renderPlaceholderRow();
                    ensurePlaceholderAtBottom();
                }
            };

            // Sanitize input as user types
            tbody.addEventListener('input', (e) => {
                const input = e.target && e.target.closest('input.perm-role');
                if (!input) return;
                const caret = input.selectionStart;
                const clean = sanitizeRole(input.value);
                if (clean !== input.value) {
                    input.value = clean;
                    try { input.setSelectionRange(caret, caret); } catch(_){}
                }
            });
        }

        _collectPermissions() {
            const r = this.shadowRoot;
            const rows = Array.from(r.querySelectorAll('#perm-tbody tr.saved'));
            const out = [];
            const seen = new Set();
            rows.forEach(tr => {
                const type = (tr.getAttribute('data-type') === 'deny') ? 'deny' : 'allow';
                const role = String(tr.getAttribute('data-role') || '').trim();
                if (!role) return;
                const key = `${type}:${role}`;
                if (seen.has(key)) return;
                seen.add(key);
                out.push({ type, role });
            });
            return out;
        }

        _validatePayload(payload) {
            // Basic required fields
            const id = String(payload.id || '').trim();
            if (!id) return 'Service ID is required';
            if (!/^[A-Za-z0-9][A-Za-z0-9_-]{1,62}$/.test(id)) return 'Service ID must be 2-63 chars, alphanumeric plus - _';
            const name = String(payload.name || '').trim();
            if (!name) return 'Service name is required';

            if (payload.type === 'http') {
                const url = String(payload.url || '').trim();
                if (!url) return 'Target URL is required';
                try {
                    const u = new URL(url);
                    if (u.protocol !== 'http:' && u.protocol !== 'https:') return 'URL must use http or https';
                    if (!u.hostname) return 'URL must include a hostname';
                    const port = u.port ? parseInt(u.port, 10) : (u.protocol==='https:'?443:80);
                    if (!(port >= 1 && port <= 65535)) return 'URL port must be 1-65535';
                } catch (_) {
                    return 'Target URL is invalid';
                }
            } else if (payload.type === 'ssh') {
                const host = String(payload.host || '').trim();
                const port = parseInt(payload.port, 10);
                if (!host) return 'Target host is required';
                if (host.includes('://')) return 'SSH target should not include a scheme';
                if (!(port >= 1 && port <= 65535)) return 'SSH port must be 1-65535';
            }

            // Permissions sanity
            if (!Array.isArray(payload.permissions)) payload.permissions = [];
            for (const p of payload.permissions) {
                if (p.type !== 'allow' && p.type !== 'deny') return 'Permission type must be allow or deny';
                if (!p.role || /\s/.test(p.role)) return 'Permission role must be non-empty without spaces';
            }

            return '';
        }
    }

    if (!customElements.get('app-service-modal')) customElements.define('app-service-modal', AppServiceModal);

    // Admin-specific service cards (with full actions)
    class AppAdminServiceCardBase extends HTMLElement {
        static get observedAttributes() { return ['name','enabled','type']; }
        constructor(){
            super();
            this.attachShadow({ mode:'open' });
            this._data = null;
            this._tpl = createTemplate(`
                <style>
                    :host { display: block; }
                    .card { 
                        border: 1px solid var(--clr-border-muted); 
                        border-radius: var(--radius-lg); 
                        padding: 0; 
                        background: var(--clr-bg-highlight); 
                        box-shadow: var(--shadow-sm);
                        transition: all 0.2s ease;
                        display: flex;
                        flex-direction: column;
                        height: 100%;
                        cursor: pointer;
                        overflow: hidden;
                    }
                    .card:hover {
                        transform: translateY(-2px);
                        box-shadow: var(--shadow-md);
                        border-color: var(--clr-primary-base);
                    }
                    .card-content {
                        padding: 16px;
                        flex: 1;
                        display: flex;
                        flex-direction: column;
                        background: var(--clr-bg-highlight);
                    }
                    .icon-wrapper {
                        width: 40px;
                        height: 40px;
                        border-radius: var(--radius-md);
                        background: var(--clr-bg-surface);
                        display: flex;
                        align-items: center;
                        justify-content: center;
                        margin-bottom: 12px;
                        flex-shrink: 0;
                    }
                    .icon-wrapper svg {
                        color: var(--clr-primary-base);
                    }
                    .icon-wrapper img {
                        object-fit: contain;
                    }
                    .header { 
                        margin-bottom: 8px;
                        flex: 1;
                    }
                    .name { 
                        font-weight: 600; 
                        font-size: 15px; 
                        color: var(--clr-text-high);
                        line-height: 1.3;
                        margin: 0;
                    }
                    .badges { 
                        display: flex; 
                        gap: .5rem; 
                        align-items: center; 
                        margin-top: 8px;
                    }
                    .badge { 
                        font-size: 11px; 
                        padding: 4px 8px; 
                        border-radius: 9999px; 
                        background: var(--clr-bg-surface); 
                        color: var(--clr-text-high);
                        font-weight: 500;
                    }
                    .badge.type {
                        background: var(--clr-primary-base);
                        color: var(--clr-highlight);
                    }
                    .badge.status.enabled { 
                        background: var(--clr-success); 
                        color: #fff; 
                    }
                    .badge.status.disabled { 
                        background: var(--clr-danger); 
                        color: #fff; 
                    }
                    .meta { 
                        font-size: 13px; 
                        color: var(--clr-text-muted); 
                        line-height: 1.5;
                        word-break: break-word;
                        flex: 1;
                    }
                    .meta .row { 
                        margin: 4px 0; 
                    }
                    .meta .row:first-child {
                        margin-top: 0;
                    }
                    .meta .row:last-child {
                        margin-bottom: 0;
                    }
                    .label { 
                        color: var(--clr-text-muted); 
                        font-weight: 500;
                    }
                    .value { 
                        color: var(--clr-text-high); 
                    }
                    .actions { 
                        padding: 12px 16px;
                        background: var(--clr-bg-highlight);
                        border-top: 1px solid var(--clr-border-muted);
                        margin-top: auto;
                        display: flex;
                        gap: .5rem;
                        justify-content: flex-end;
                    }
                    .btn { 
                        border: 1px solid var(--clr-border); 
                        background: var(--clr-bg-highlight); 
                        padding: 8px; 
                        border-radius: var(--radius-md); 
                        cursor: pointer; 
                        font-size: 13px;
                        color: var(--clr-text-high);
                        transition: all 0.15s ease;
                        display: inline-flex;
                        align-items: center;
                        justify-content: center;
                        min-width: 36px;
                        min-height: 36px;
                    }
                    .btn:hover { 
                        background: var(--clr-bg-dark);
                        transform: translateY(-1px);
                    }
                    .btn:active {
                        transform: translateY(0);
                    }
                    .btn.status { 
                        color: var(--clr-primary-base); 
                        border-color: var(--clr-primary-base);
                    }
                    .btn.status:hover {
                        background: var(--clr-primary-base);
                        color: var(--clr-highlight);
                    }
                    .btn.open {
                        color: var(--clr-success);
                        border-color: var(--clr-success);
                    }
                    .btn.open:hover {
                        background: var(--clr-success);
                        color: #fff;
                    }
                    .btn.edit {
                        color: var(--clr-warning);
                        border-color: var(--clr-warning);
                    }
                    .btn.edit:hover {
                        background: var(--clr-warning);
                        color: #fff;
                    }
                    .btn.toggle {
                        color: var(--clr-secondary);
                        border-color: var(--clr-secondary);
                    }
                    .btn.toggle:hover {
                        background: var(--clr-secondary);
                        color: #fff;
                    }
                    .btn.delete {
                        color: var(--clr-danger);
                        border-color: var(--clr-danger);
                    }
                    .btn.delete:hover {
                        background: var(--clr-danger);
                        color: #fff;
                    }
                    .btn-icon {
                        display: inline-block;
                        width: 16px;
                        height: 16px;
                        background-color: currentColor;
                        -webkit-mask-size: contain;
                        -webkit-mask-repeat: no-repeat;
                        -webkit-mask-position: center;
                        mask-size: contain;
                        mask-repeat: no-repeat;
                        mask-position: center;
                    }
                    .icon-chart { -webkit-mask-image: url(/static/icons/chart.svg); mask-image: url(/static/icons/chart.svg); }
                    .icon-external-link { -webkit-mask-image: url(/static/icons/external-link.svg); mask-image: url(/static/icons/external-link.svg); }
                    .icon-edit { -webkit-mask-image: url(/static/icons/edit.svg); mask-image: url(/static/icons/edit.svg); }
                    .icon-refresh { -webkit-mask-image: url(/static/icons/refresh.svg); mask-image: url(/static/icons/refresh.svg); }
                    .icon-trash { -webkit-mask-image: url(/static/icons/trash.svg); mask-image: url(/static/icons/trash.svg); }
                    .icon-plus { -webkit-mask-image: url(/static/icons/plus.svg); mask-image: url(/static/icons/plus.svg); }
                    .icon-search { -webkit-mask-image: url(/static/icons/search.svg); mask-image: url(/static/icons/search.svg); }
                    .icon-clear { -webkit-mask-image: url(/static/icons/clear.svg); mask-image: url(/static/icons/clear.svg); }
                    .icon-check { -webkit-mask-image: url(/static/icons/check.svg); mask-image: url(/static/icons/check.svg); }
                    .icon-close { -webkit-mask-image: url(/static/icons/close.svg); mask-image: url(/static/icons/close.svg); }
                </style>
                <div class="card">
                    <div class="card-content">
                        <div class="icon-wrapper">
                            <div class="icon"></div>
                        </div>
                        <div class="header">
                            <div class="name"></div>
                            <div class="badges">
                                <span class="badge type"></span>
                                <span class="badge status"></span>
                            </div>
                        </div>
                        <div class="meta"></div>
                    </div>
                    <div class="actions">
                        <button class="btn status" title="Status"><span class="btn-icon icon-chart"></span></button>
                        <button class="btn open" title="Open"><span class="btn-icon icon-external-link"></span></button>
                        <button class="btn edit" title="Edit"><span class="btn-icon icon-edit"></span></button>
                        <button class="btn toggle" title="Toggle"><span class="btn-icon icon-refresh"></span></button>
                        <button class="btn delete" title="Delete"><span class="btn-icon icon-trash"></span></button>
                    </div>
                </div>
            `);
        }
        set data(v){ this._data = v || null; this.render(); }
        get data(){ return this._data; }
        connectedCallback(){ this._ensure(); this._wire(); this.render(); }
        attributeChangedCallback(){ this.render(); }
        _ensure(){ const r=this.shadowRoot; if (!r.firstChild) r.appendChild(this._tpl.content.cloneNode(true)); }
        render(){
            this._ensure();
            const r=this.shadowRoot; const d=this._data||{};
            const nameEl=r.querySelector('.name'); const typeEl=r.querySelector('.type'); const statusEl=r.querySelector('.status'); const metaEl=r.querySelector('.meta');
            const iconEl=r.querySelector('.icon');
            const name = this.getAttribute('name') || d.name || d.id || '';
            const type = (this.getAttribute('type') || d.type || '').toLowerCase();
            const enabled = (this.getAttribute('enabled') ?? (d.enabled ? 'true' : 'false')) === 'true';
            if (nameEl) nameEl.textContent = name;
            if (typeEl) typeEl.textContent = type || 'service';
            if (statusEl) { statusEl.textContent = enabled ? 'Enabled' : 'Disabled'; statusEl.className = `badge status ${enabled?'enabled':'disabled'}`; }
            if (metaEl) metaEl.textContent = '';
            
            // Set icon based on service type
            if (iconEl) {
                if (type === 'http') {
                    let faviconHtml = '';
                    if (d.id) {
                        const faviconUrl = `/api/v1/services/http/${d.id}/favicon`;
                        faviconHtml = `<img src="${faviconUrl}" alt="" onerror="this.src='data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 100 100%22><text y=%22.9em%22 font-size=%2290%22>🌐</text></svg>';" style="width:24px;height:24px;">`;
                    } else {
                        faviconHtml = `<span style="font-size: 20px;">🌐</span>`;
                    }
                    iconEl.innerHTML = faviconHtml;
                } else if (type === 'ssh') {
                    const sshIconSvg = `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"></polyline><line x1="12" y1="19" x2="20" y2="19"></line></svg>`;
                    iconEl.innerHTML = sshIconSvg;
                } else {
                    iconEl.innerHTML = `<span style="font-size: 20px;">⚙</span>`;
                }
            }
        }
        _wire(){ 
            if (this._isWired) return; // Prevent duplicate bindings
            this._isWired = true;
            
            const r=this.shadowRoot; 
            const statusBtn=r.querySelector('.btn.status'); 
            const openBtn=r.querySelector('.btn.open'); 
            const editBtn=r.querySelector('.btn.edit'); 
            const toggleBtn=r.querySelector('.btn.toggle'); 
            const deleteBtn=r.querySelector('.btn.delete');
            
            // Make entire card clickable (opens the service)
            const card = r.querySelector('.card');
            card && card.addEventListener('click', (e) => {
                // Don't trigger if clicking on a button (avoid double navigation)
                if (!e.target.closest('.btn')) {
                    this._emit('open');
                }
            });
            
            statusBtn && statusBtn.addEventListener('click', (e) => {
                e.stopPropagation();
                this._emit('status');
            });
            openBtn && openBtn.addEventListener('click', (e) => {
                e.stopPropagation();
                this._emit('open');
            });
            editBtn && editBtn.addEventListener('click', (e) => {
                e.stopPropagation();
                this._emit('edit');
            });
            toggleBtn && toggleBtn.addEventListener('click', (e) => {
                e.stopPropagation();
                this._emit('toggle');
            });
            deleteBtn && deleteBtn.addEventListener('click', (e) => {
                e.stopPropagation();
                this._emit('delete');
            });
        }
        _emit(action){ this.dispatchEvent(new CustomEvent('service-action',{ bubbles:true, composed:true, detail:{ action, service:this._data } })); }
    }

    class AppAdminHttpServiceCard extends AppAdminServiceCardBase {
        render(){
            super.render();
            const r=this.shadowRoot; const meta=r && r.querySelector('.meta'); const d=this._data||{};
            if (!meta) return;
            const description = d.description || '';
            const url = (d && (d.url || (d.protocol&&d.host?`${d.protocol}://${d.host}:${d.port||80}${d.path||'/'}`:''))) || '';
			const allows = Array.isArray(d.permissions) ? d.permissions.filter(p=>p && p.type==='allow' && p.role).map(p=>String(p.role)) : [];
			const denies = Array.isArray(d.permissions) ? d.permissions.filter(p=>p && p.type==='deny' && p.role).map(p=>String(p.role)) : [];
            const id = d.id || '';
            const parts = [];
            if (description) parts.push(`<div>${description}</div>`);
            if (url) parts.push(`<div><span class="label">URL:</span> <span class="value">${url}</span></div>`);
			if (allows.length) parts.push(`<div><span class="label">Allow:</span> <span class="value">${allows.join(', ')}</span></div>`);
			if (denies.length) parts.push(`<div><span class="label">Deny:</span> <span class="value">${denies.join(', ')}</span></div>`);
            if (id) parts.push(`<div><span class="label">Service ID:</span> <span class="value">${id}</span></div>`);
            meta.innerHTML = parts.join('');
        }
    }
    class AppAdminSshServiceCard extends AppAdminServiceCardBase {
        render(){
            super.render();
            const r=this.shadowRoot; const meta=r && r.querySelector('.meta'); const d=this._data||{};
            if (!meta) return;
            const description = d.description || '';
            const target = d && d.host ? `${d.host}:${d.port||22}` : '';
			const allows = Array.isArray(d.permissions) ? d.permissions.filter(p=>p && p.type==='allow' && p.role).map(p=>String(p.role)) : [];
			const denies = Array.isArray(d.permissions) ? d.permissions.filter(p=>p && p.type==='deny' && p.role).map(p=>String(p.role)) : [];
            const id = d.id || '';
            const parts = [];
            if (description) parts.push(`<div>${description}</div>`);
            if (target) parts.push(`<div><span class="label">Target:</span> <span class="value">${target}</span></div>`);
			if (allows.length) parts.push(`<div><span class="label">Allow:</span> <span class="value">${allows.join(', ')}</span></div>`);
			if (denies.length) parts.push(`<div><span class="label">Deny:</span> <span class="value">${denies.join(', ')}</span></div>`);
            if (id) parts.push(`<div><span class="label">Service ID:</span> <span class="value">${id}</span></div>`);
            meta.innerHTML = parts.join('');
        }
    }
    if (!customElements.get('app-admin-http-service-card')) customElements.define('app-admin-http-service-card', AppAdminHttpServiceCard);
    if (!customElements.get('app-admin-ssh-service-card')) customElements.define('app-admin-ssh-service-card', AppAdminSshServiceCard);

    // Admin services component
    class AppAdminServices extends HTMLElement {
        constructor(){ super(); this.attachShadow({ mode:'open' }); this._rootTpl = createTemplate(`
            <style>
                .panel { background: var(--clr-bg-highlight); border:1px solid var(--clr-border-muted); border-radius: var(--radius-lg); margin:12px 0; box-shadow: var(--shadow-sm); }
                .panel-header { padding:16px 20px;display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid var(--clr-border); }
                .panel-content { padding:16px 20px; }
                .grid { display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap: var(--spacing-lg); }
                .btn { border:1px solid var(--clr-border); background: var(--clr-bg-highlight); padding:8px 16px; border-radius: var(--radius-md); cursor:pointer; font-size:13px; color: var(--clr-text-high); transition: all 0.15s ease; display: inline-flex; align-items: center; gap: 6px; }
                .btn:hover { background: var(--clr-bg-dark); transform: translateY(-1px); }
                .btn.primary { background: var(--clr-primary-base); color: var(--clr-highlight); border-color: var(--clr-primary-base); }
                .btn.primary:hover { background: var(--clr-primary-light); }
                .btn-icon { display: inline-block; width: 14px; height: 14px; background-color: currentColor; -webkit-mask-size: contain; -webkit-mask-repeat: no-repeat; -webkit-mask-position: center; mask-size: contain; mask-repeat: no-repeat; mask-position: center; }
                .icon-plus { -webkit-mask-image: url(/static/icons/plus.svg); mask-image: url(/static/icons/plus.svg); }
                .icon-refresh { -webkit-mask-image: url(/static/icons/refresh.svg); mask-image: url(/static/icons/refresh.svg); }
            </style>
            <section class="panel">
                <div class="panel-header">
                    <h2 id="title">Services</h2>
                    <div style="display: flex; gap: 8px;">
                        <button class="btn primary" id="add" title="Add Service">
                            <span class="btn-icon icon-plus"></span>
                            <span>Add</span>
                        </button>
                        <button class="btn" id="refresh" title="Refresh">
                            <span class="btn-icon icon-refresh"></span>
                            <span>Refresh</span>
                        </button>
                    </div>
                </div>
                <div class="panel-content">
                    <div class="grid" id="grid"></div>
                </div>
            </section>
        `); this._type = 'http'; }
        static get observedAttributes(){ return ['type']; }
        attributeChangedCallback(name, oldValue, newValue){
            if (name !== 'type') return;
            if (oldValue === newValue) return;
            this._type = (newValue||'http').toLowerCase();
            // Avoid double refresh on initial connect
            if (this._connectedOnce) this.refresh();
        }
        connectedCallback(){
            const r=this.shadowRoot;
            if (!r.firstChild) r.appendChild(this._rootTpl.content.cloneNode(true));
            this._wire();
            this._connectedOnce = true;
            this.refresh();
        }
        _wire(){ const r=this.shadowRoot; r.getElementById('refresh').addEventListener('click',()=>this.refresh()); r.getElementById('add').addEventListener('click',()=>this._openAdd()); }
        async refresh(){
            if (this._isRefreshing) return;
            this._isRefreshing = true;
            try {
                await whenApiClientReady();
                const r=this.shadowRoot;
                if (!r.firstChild) r.appendChild(this._rootTpl.content.cloneNode(true));
                const grid=r.getElementById('grid');
                if (!grid) { this._isRefreshing=false; return; }
                grid.innerHTML='';
                const title=r.getElementById('title');
                if (title) title.textContent = (this._type==='ssh'?'SSH':'Web') + ' Services';
                const resp = (this._type==='ssh') ? await window.apiClient.services.ssh.list(false,{expandPermissions:true}) : await window.apiClient.services.http.list(false,{expandPermissions:true});
                const base = (resp && (resp.data!==undefined ? resp.data : resp)) || [];
				const services = Array.isArray(base) ? base : (base && Array.isArray(base.services) ? base.services : (base && base.services ? Object.values(base.services) : []));
				const byTitle = (a, b) => {
					const an = String((a && (a.name || a.id)) || '');
					const bn = String((b && (b.name || b.id)) || '');
					return an.localeCompare(bn, undefined, { numeric: true, sensitivity: 'base' });
				};
				const sorted = services.slice().sort(byTitle);
				for (const s of sorted) {
                    const el = (this._type==='ssh') ? document.createElement('app-admin-ssh-service-card') : document.createElement('app-admin-http-service-card');
                    el.data = Object.assign({}, s, { type: this._type });
                    el.addEventListener('service-action', (e)=> this._onAction(e));
                    grid.appendChild(el);
                }
            } catch(e){
                console.error('admin services refresh failed', e);
            } finally {
                this._isRefreshing = false;
            }
        }
        _openAdd(){ const modal = document.querySelector('app-service-modal') || document.body.appendChild(document.createElement('app-service-modal')); modal.addEventListener('service-save', async (ev)=>{ const payload = ev.detail && ev.detail.payload; if (!payload) return; try { if (payload.type==='ssh') await window.apiClient.services.ssh.create(payload); else await window.apiClient.services.http.create(payload); window.notifications && notifications.success('Service created'); this.refresh(); } catch(e){ console.error(e); window.notifications && notifications.error('Create failed'); } }, { once: true }); modal.open(null, this._type); }
        async _onAction(e){ const action = e.detail && e.detail.action; const svc = e.detail && e.detail.service; if (!action || !svc || !svc.id) return; try { if (action==='open') { const href = (this._type==='ssh') ? `/ssh/${svc.id}` : `/http/${svc.id}`; window.open(href,'_blank'); return; } if (action==='status') { const modal = document.querySelector('app-service-status-modal') || document.body.appendChild(document.createElement('app-service-status-modal')); modal.open(svc); return; } if (action==='toggle') { await window.apiClient.services[this._type].toggle(svc.id); window.notifications && notifications.success('Toggled ' + svc.id); this.refresh(); } else if (action==='delete') { if (!confirm('Delete ' + svc.id + '?')) return; await window.apiClient.services[this._type].delete(svc.id); window.notifications && notifications.success('Deleted ' + svc.id); this.refresh(); } else if (action==='edit') { const modal = document.querySelector('app-service-modal') || document.body.appendChild(document.createElement('app-service-modal')); modal.addEventListener('service-save', async (ev)=>{ const payload = ev.detail && ev.detail.payload; if (!payload) return; await window.apiClient.services[this._type].update(svc.id, payload); window.notifications && notifications.success('Updated ' + svc.id); this.refresh(); }, { once: true }); modal.open(svc, this._type); } } catch (err) { console.error(err); window.notifications && notifications.error('Operation failed'); } }
    }

    if (!customElements.get('app-admin-services')) customElements.define('app-admin-services', AppAdminServices);
    // Admin monitoring component
    class AppAdminMonitoring extends HTMLElement {
        constructor(){
            super();
            this.attachShadow({ mode: 'open' });
			this._state = { limit: 100, offset: 0, flow: '', status: '', text: '', since: '', until: '', since_epoch: undefined, until_epoch: undefined, grouped: true };
            this._rootTpl = createTemplate(`
                <style>
                    .panel { background: var(--clr-bg-highlight); border:1px solid var(--clr-border-muted); border-radius: var(--radius-lg); margin:12px 0; box-shadow: var(--shadow-sm); }
                    .panel-header { padding:12px 16px;display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid var(--clr-border); }
                    .panel-content { padding:12px 16px; }
                    .filters { display:flex; flex-direction:column; gap:.5rem; margin-bottom:1rem; }
                    .filters-grid .filter-search { width:100%; padding:.5rem .6rem; }
                    .filters-row { display:flex; flex-wrap:wrap; gap:.5rem; align-items:center; }
                    /* Make controls use available width while keeping sensible minimums */
                    .filters-row select, .filters-row label, .filters-row input:not(.filter-search) { flex: 1 1 160px; }
                    .filters-row button { flex: 0 0 auto; }
                    .filters input, .filters select { min-width:160px; }
                    /* Reuse input styles consistent with service modal for dark theme */
                    .filters input[type="search"],
                    .filters input[type="number"],
                    .filters input[type="datetime-local"],
                    .filters select {
                        border:1px solid var(--clr-border);
                        border-radius: var(--radius-md);
                        padding:6px 8px;
                        font-size:13px;
                        background: var(--clr-bg-highlight);
                        color: var(--clr-text-high);
                    }
                    /* Fix calendar icon color in datetime-local inputs for dark theme */
                    .filters input[type="datetime-local"]::-webkit-calendar-picker-indicator {
                        filter: invert(1);
                    }
                    .filters input[type="datetime-local"]::-webkit-datetime-edit-text {
                        color: var(--clr-text-high);
                    }
                    .filters input[type="datetime-local"]::-webkit-datetime-edit-month-field,
                    .filters input[type="datetime-local"]::-webkit-datetime-edit-day-field,
                    .filters input[type="datetime-local"]::-webkit-datetime-edit-year-field {
                        color: var(--clr-text-high);
                    }
                    .filters input[type="datetime-local"]::-webkit-datetime-edit-hour-field,
                    .filters input[type="datetime-local"]::-webkit-datetime-edit-minute-field {
                        color: var(--clr-text-high);
                    }
                    .data-table { width:100%; border-collapse: collapse; table-layout: fixed; }
                    .data-table th, .data-table td { border-bottom:1px solid var(--clr-border-muted); padding:6px 8px; text-align:left; vertical-align: top; }
                    .data-table th { position: sticky; top: 0; background: var(--clr-bg-highlight); z-index: 1; }
                    .code { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace; font-size:12px; }
                    .btn { border:1px solid var(--clr-border); background: var(--clr-bg-highlight); padding:6px 10px; border-radius: var(--radius-md); cursor:pointer; font-size:13px; color: var(--clr-text-high); display: inline-flex; align-items: center; gap: 6px; }
                    .btn:hover { background: var(--clr-bg-dark); }
                    .btn.primary { background: var(--clr-primary-base); color: var(--clr-highlight); border-color: var(--clr-primary-base); }
                    .btn.primary:hover { background: var(--clr-primary-light); }
                    .btn.secondary { background: var(--clr-secondary); color: #fff; border-color: var(--clr-secondary); }
                    .btn.secondary:hover { opacity: 0.9; }
                    .btn-icon { display: inline-block; width: 14px; height: 14px; background-color: currentColor; -webkit-mask-size: contain; -webkit-mask-repeat: no-repeat; -webkit-mask-position: center; mask-size: contain; mask-repeat: no-repeat; mask-position: center; }
                    .icon-refresh { -webkit-mask-image: url(/static/icons/refresh.svg); mask-image: url(/static/icons/refresh.svg); }
                    .icon-search { -webkit-mask-image: url(/static/icons/search.svg); mask-image: url(/static/icons/search.svg); }
                    .icon-clear { -webkit-mask-image: url(/static/icons/clear.svg); mask-image: url(/static/icons/clear.svg); }
                    .pagination { display:flex; justify-content:center; gap:.5rem; }
                    /* Improve row rendering */
                    .data-table td { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
                    .data-table td.code { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
                    .data-table td.info { white-space: normal; overflow: visible; }
                    .data-table td.info details { display:block; max-width:100%; }
                    .data-table details summary { cursor: pointer; color: var(--clr-text-muted); }
                    .data-table pre { margin: 6px 0 0; background: var(--clr-bg-dark); color: var(--clr-text-high); padding: 8px; border-radius: var(--radius-md); overflow: auto; max-height: 280px; white-space: pre-wrap; word-break: break-word; }
                    /* Details row placed below event row */
                    .details-row td { padding: 0 8px 10px 8px; background: var(--clr-bg-highlight); border-bottom: 1px solid var(--clr-border-muted); }
                    .details-content { background: var(--clr-bg-dark); border:1px solid var(--clr-border-muted); border-radius: var(--radius-md); padding: 8px; margin-top: 6px; max-height: 320px; overflow: auto; }
                    .expand-toggle { appearance: none; border: 0; background: none; color: var(--clr-text-muted); text-decoration: underline; cursor: pointer; padding: 0; font-size: 12px; }
                    .expand-toggle[aria-expanded="true"] { color: var(--clr-text-high); }
                    /* Proportional column widths (5 columns) */
                    .data-table thead th:nth-child(1), .data-table tbody td:nth-child(1) { width: 20%; }
                    .data-table thead th:nth-child(2), .data-table tbody td:nth-child(2) { width: 12%; }
                    .data-table thead th:nth-child(3), .data-table tbody td:nth-child(3) { width: 14%; }
                    .data-table thead th:nth-child(4), .data-table tbody td:nth-child(4) { width: 24%; }
                    .data-table thead th:nth-child(5), .data-table tbody td:nth-child(5) { width: 30%; }
                    /* Group styling */
                    .group { border:1px solid var(--clr-border-muted); border-radius: var(--radius-lg); background: var(--clr-bg-dark); margin-bottom:12px; box-shadow: var(--shadow-sm); }
                    .group-header { display:flex; align-items:center; justify-content:space-between; padding:10px 12px; cursor:pointer; }
                    .group-header .title { display:flex; gap:.5rem; align-items:center; }
                    .group-header .sid { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace; font-size:12px; background: var(--clr-bg-dark); padding:2px 6px; border-radius: 999px; }
                    .group-header .meta { color: var(--clr-text-muted); font-size:12px; }
                    .group-body { display:none; border-top:1px solid var(--clr-border); overflow-x:hidden; }
                    .group.open .group-body { display:block; }
                    .chevron { display:inline-block; transition: transform .15s ease; }
                    .group.open .chevron { transform: rotate(90deg); }
                </style>
                <section class="panel">
                    <div class="panel-header">
                        <h2>Monitoring</h2>
                        <div>
                            <button class="btn" id="refresh" title="Refresh">
                                <span class="btn-icon icon-refresh"></span>
                                <span>Refresh</span>
                            </button>
                        </div>
                    </div>
						<div class="panel-content">
							<div class="filters filters-grid">
								<input type="search" id="f-text" class="filter-search" placeholder="Search logs (user, session, service, path, message…)" />
								<div class="filters-row">
									<select id="f-flow"><option value="">All flows</option><option value="auth">Auth</option><option value="http">HTTP</option><option value="ssh">SSH</option></select>
									<select id="f-status"><option value="">All status</option><option value="success">Success</option><option value="failure">Failure</option><option value="info">Info</option><option value="view">View</option></select>
									<label style="display:flex;align-items:center;gap:.25rem;">From <input type="datetime-local" id="f-since" title="From" /></label>
									<label style="display:flex;align-items:center;gap:.25rem;">To <input type="datetime-local" id="f-until" title="To" /></label>
                                    <input type="number" id="f-limit" list="page-sizes" min="1" value="100" style="max-width:120px;" />
                                    <datalist id="page-sizes"><option value="25"></option><option value="50"></option><option value="100"></option><option value="200"></option></datalist>
                                    <button class="btn primary" id="apply" title="Search">
                                        <span class="btn-icon icon-search"></span>
                                        <span>Search</span>
                                    </button>
                                    <button class="btn secondary" id="clear" title="Clear Filters">
                                        <span class="btn-icon icon-clear"></span>
                                        <span>Clear</span>
                                    </button>
								</div>
							</div>
                        <div id="events"></div>
                        <div class="pagination" id="pagination"></div>
                    </div>
                </section>
            `);
        }
        connectedCallback(){ this.render(); this._wire(); this.refresh(); }
        render(){ const root=this.shadowRoot; if (!root.firstChild) root.appendChild(this._rootTpl.content.cloneNode(true)); }
        _wire(){
            const r=this.shadowRoot;
			r.getElementById('apply').addEventListener('click',()=>{ this._apply(); });
            r.getElementById('clear').addEventListener('click',()=>{ this._clear(); });
            r.getElementById('refresh').addEventListener('click',()=>{ this.refresh(); });
			['f-text','f-flow','f-status','f-since','f-until','f-limit'].forEach(id=>{
                const el = r.getElementById(id);
                el && el.addEventListener('change',()=> this._apply(false));
            });
			const text = r.getElementById('f-text');
			text && text.addEventListener('keydown',(e)=>{ if (e.key === 'Enter') { e.preventDefault(); this._apply(); } });
        }
        _apply(resetOffset=true){
            const r=this.shadowRoot;
            const s=this._state;
			s.text=(r.getElementById('f-text').value||'').trim();
			s.flow=r.getElementById('f-flow').value||'';
			s.status=r.getElementById('f-status').value||'';
            const sinceEl = r.getElementById('f-since');
            const untilEl = r.getElementById('f-until');
            const sinceInput = (sinceEl && sinceEl.value) || '';
            const untilInput = (untilEl && untilEl.value) || '';
            
            // Convert datetime-local inputs to Unix timestamps
            s.since_epoch = window.DateTimeUtil ? window.DateTimeUtil.localDateTimeToEpoch(sinceInput) : null;
            s.until_epoch = window.DateTimeUtil ? window.DateTimeUtil.localDateTimeToEpoch(untilInput) : null;
            s.limit=parseInt(r.getElementById('f-limit').value,10)||100;
            if (resetOffset) s.offset=0;
            this.refresh();
        }
        _clear(){
            const r=this.shadowRoot;
			['f-text','f-flow','f-status','f-since','f-until'].forEach(id=>{ const el=r.getElementById(id); if (el) el.value=''; });
			const s=this._state; Object.assign(s,{ text:'',flow:'',status:'',since:'',until:'', since_epoch: undefined, until_epoch: undefined, offset:0 });
            this.refresh();
        }
        async refresh(){
            try{
                await whenApiClientReady();
                const s=this._state;
                const params={ limit:s.limit, offset:s.offset, grouped: true };
				if (s.flow) params.flow=s.flow;
				if (s.status) params.status=s.status;
                // Send only epoch filters to avoid any timezone ambiguity
                if (typeof s.since_epoch === 'number' && !Number.isNaN(s.since_epoch)) params.since_epoch = s.since_epoch;
                if (typeof s.until_epoch === 'number' && !Number.isNaN(s.until_epoch)) params.until_epoch = s.until_epoch;
                if (s.text) params.q=s.text;
                const resp=await window.apiClient.monitoring.listEvents(params);
                const rawGroups = resp && resp.data && resp.data.groups;
                const groups = Array.isArray(rawGroups) ? rawGroups : (rawGroups ? Object.values(rawGroups) : []);
                const totalGroups = Number((resp && resp.data && resp.data.total_groups)) || groups.length || 0;
                this._renderGroups(groups, totalGroups);
            } catch(e){ console.error('monitoring load failed', e); }
        }
        _render(events, total){
            const r=this.shadowRoot;
            const list=r.getElementById('events');
            const pag=r.getElementById('pagination');
            if (!events.length) { list.innerHTML = '<div>No events</div>'; pag.innerHTML=''; return; }
            const fmtTs = (ts) => {
                return window.DateTimeUtil ? window.DateTimeUtil.formatForDisplay(ts) : ts;
            };
            const renderRow = (ev, idx)=>{
                const req = (ev.request_method||'') + (ev.request_uri?` ${ev.request_uri}`:'');
                const md = ev.metadata||{};
                const statusCode = (md && (md.status || md.status_code)) ? ` (${md.status || md.status_code})` : '';
                const rid = String(ev.id || idx);
                const hasDetails = Object.keys(md).length > 0;
                const toggle = hasDetails ? ` <button class="expand-toggle" data-expand="${rid}" aria-expanded="false">Details</button>` : '';
                const detailsRow = hasDetails ? `<tr class="details-row" data-detail-for="${rid}" style="display:none;"><td colspan="5"><div class="details-content"><pre>${JSON.stringify(md,null,2)}</pre></div></td></tr>` : '';
                return `<tr data-row="event" data-id="${rid}"><td>${fmtTs(ev.timestamp)}</td><td>${ev.flow||''}</td><td>${(ev.status||'')}${statusCode}</td><td class="code">${req}</td><td class="info">${ev.description||''}${toggle}</td></tr>${detailsRow}`;
            };
            list.innerHTML = `
                <div class="panel"><div class="panel-content">
                    <table class="data-table"><thead><tr><th>Time</th><th>Flow</th><th>Status</th><th>Request</th><th>Info</th></tr></thead><tbody>
                    ${events.map((e,i)=>renderRow(e,i)).join('')}
                    </tbody></table>
                </div></div>`;
            // Wire expand toggles (event delegation)
            list.addEventListener('click', (e)=>{
                const btn = e.target && e.target.closest('.expand-toggle');
                if (!btn) return;
                e.preventDefault(); e.stopPropagation();
                const id = btn.getAttribute('data-expand');
                const row = list.querySelector(`.details-row[data-detail-for="${id}"]`);
                if (!row) return;
                const isHidden = row.style.display === 'none';
                row.style.display = isHidden ? '' : 'none';
                btn.setAttribute('aria-expanded', isHidden ? 'true' : 'false');
                btn.textContent = isHidden ? 'Hide' : 'Details';
            });
            const pages = Math.max(1, Math.ceil((total||events.length)/(this._state.limit||100)));
            const current = Math.floor((this._state.offset||0)/(this._state.limit||100))+1;
            let html='';
            for (let p=1;p<=pages;p++) {
                if (p===current) html += `<span class="btn" aria-current="page">${p}</span>`;
                else html += `<button class="btn" data-page="${p}">${p}</button>`;
            }
            pag.innerHTML = html;
            pag.querySelectorAll('button[data-page]').forEach(btn=>{
                btn.addEventListener('click',()=>{ this._state.offset = (parseInt(btn.getAttribute('data-page'),10)-1)*(this._state.limit||100); this.refresh(); });
            });
        }

		_renderGroups(groups, totalGroups){
			const r=this.shadowRoot;
			const list=r.getElementById('events');
			const pag=r.getElementById('pagination');
			if (!groups.length) { list.innerHTML = '<div>No events</div>'; pag.innerHTML=''; return; }
            const renderGroup = (g)=>{
                const sid = g.session_id || '(no session)';
                const fmtTs = (ts) => {
                    return window.DateTimeUtil ? window.DateTimeUtil.formatForDisplay(ts) : ts;
                };
                const evs = Array.isArray(g.events) ? g.events : (g.events ? Object.values(g.events) : []);
                const username = (function(){
                    for (let i=0;i<evs.length;i++){ const u = evs[i] && evs[i].username; if (u) return u; }
                    return '';
                })();
                const rows = evs.map((ev, idx) => {
                    const req = (ev.request_method||'') + (ev.request_uri?` ${ev.request_uri}`:'');
                    const md = ev.metadata||{};
                    const rid = String(ev.id || `${sid}-${idx}`);
                    const hasDetails = Object.keys(md).length > 0;
                    const statusCode = (md && (md.status || md.status_code)) ? ` (${md.status || md.status_code})` : '';
                    const toggle = hasDetails ? ` <button class=\"expand-toggle\" data-expand=\"${rid}\" aria-expanded=\"false\">Details</button>` : '';
                    const detailsRow = hasDetails ? `<tr class=\"details-row\" data-detail-for=\"${rid}\" style=\"display:none;\"><td colspan=\"5\"><div class=\"details-content\"><pre>${JSON.stringify(md,null,2)}</pre></div></td></tr>` : '';
                    return `<tr data-row=\"event\" data-id=\"${rid}\"><td>${fmtTs(ev.timestamp)}</td><td>${ev.flow||''}</td><td>${(ev.status||'')}${statusCode}</td><td class=\"code\">${req}</td><td class=\"info\">${ev.description||''}${toggle}</td></tr>${detailsRow}`;
				}).join('');
                return `<div class=\"group\">\n                    <div class=\"group-header\" role=\"button\" tabindex=\"0\" aria-expanded=\"false\">\n                        <div class=\"title\"><span class=\"chevron\">▶</span><span><strong>Session</strong> <span class=\"sid\">${sid}</span>${username?` — <span class=\\\"user\\\">${username}</span>`:''}</span></div>\n                        <div class=\"meta\">${fmtTs(g.first_timestamp)} – ${fmtTs(g.last_timestamp)} · ${g.count||0} events</div>\n                    </div>\n                    <div class=\"group-body\">\n                        <div class=\"panel-content\" style=\"padding:8px 12px;\">\n                            <table class=\"data-table\"><thead><tr><th>Time</th><th>Flow</th><th>Status</th><th>Request</th><th>Info</th></tr></thead><tbody>${rows}</tbody></table>\n                        </div>\n                    </div>\n                </div>`;
			};
			list.innerHTML = groups.map(renderGroup).join('');

			// Wire expand/collapse (collapsed by default)
            list.querySelectorAll('.group').forEach(group => {
				const header = group.querySelector('.group-header');
				const toggle = () => {
					const isOpen = group.classList.toggle('open');
					header.setAttribute('aria-expanded', isOpen ? 'true' : 'false');
				};
				header && header.addEventListener('click', toggle);
				header && header.addEventListener('keydown', (e)=>{ if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggle(); } });
                // Delegated handler for details toggles inside group
                group.addEventListener('click', (e)=>{
                    const btn = e.target && e.target.closest('.expand-toggle');
                    if (!btn) return;
                    e.preventDefault(); e.stopPropagation();
                    if (!group.contains(btn)) return;
                const id = btn.getAttribute('data-expand');
                    const row = group.querySelector(`.details-row[data-detail-for="${id}"]`);
                    if (!row) return;
                    const isHidden = row.style.display === 'none';
                    row.style.display = isHidden ? '' : 'none';
                    btn.setAttribute('aria-expanded', isHidden ? 'true' : 'false');
                btn.textContent = isHidden ? 'Hide' : 'Details';
                });
			});

			const pages = Math.max(1, Math.ceil((totalGroups||groups.length)/(this._state.limit||100)));
			const current = Math.floor((this._state.offset||0)/(this._state.limit||100))+1;
			let html='';
			for (let p=1;p<=pages;p++) {
				if (p===current) html += `<span class=\"btn\" aria-current=\"page\">${p}</span>`;
				else html += `<button class=\"btn\" data-page=\"${p}\">${p}</button>`;
			}
			pag.innerHTML = html;
			pag.querySelectorAll('button[data-page]').forEach(btn=>{
				btn.addEventListener('click',()=>{ this._state.offset = (parseInt(btn.getAttribute('data-page'),10)-1)*(this._state.limit||100); this.refresh(); });
			});
		}
    }

    if (!customElements.get('app-admin-monitoring')) customElements.define('app-admin-monitoring', AppAdminMonitoring);
})();

// Server Diagnostics Component
(function(){
    async function whenApiClientReady(maxWaitMs = 10000) {
        const started = Date.now();
        while (!window.apiClient) {
            if (Date.now() - started > maxWaitMs) throw new Error('apiClient not ready');
            await new Promise(r => setTimeout(r, 50));
        }
    }

    class AppAdminDiagnostics extends HTMLElement {
        constructor() {
            super();
            this.attachShadow({ mode: 'open' });
            this._diagnostics = null;
        }

        connectedCallback() {
            this.shadowRoot.innerHTML = `
                <style>
                    :host { display: block; }
                    .diagnostics-container { padding: 20px; }
                    .section { margin-bottom: 24px; }
                    .section:last-child { margin-bottom: 0; }
                    .section-title { font-size: 16px; font-weight: 600; margin-bottom: 12px; color: var(--clr-text-high); }
                    .diagnostics-table { width: 100%; border-collapse: collapse; background: var(--clr-bg-dark); border: 1px solid var(--clr-border); border-radius: var(--radius-md); overflow: hidden; }
                    .diagnostics-table th { padding: 12px 16px; text-align: left; font-size: 13px; font-weight: 600; color: var(--clr-text-muted); background: var(--clr-bg-dark); border-bottom: 1px solid var(--clr-border); }
                    .diagnostics-table td { padding: 10px 16px; font-size: 13px; color: var(--clr-text-high); border-bottom: 1px solid var(--clr-border-muted); }
                    .diagnostics-table tr:last-child td { border-bottom: none; }
                    .diagnostics-table .param { font-weight: 600; color: var(--clr-text-high); }
                    .diagnostics-table .value { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace; color: var(--clr-primary-base); }
                    .loading { padding: 40px; text-align: center; color: var(--clr-text-muted); }
                    .refresh-btn { margin-bottom: 16px; }
                    .btn { border:1px solid var(--clr-border); background: var(--clr-bg-highlight); padding:8px 12px; border-radius: var(--radius-md); cursor:pointer; color: var(--clr-text-high); font-size:13px; display: inline-flex; align-items: center; gap: 6px; transition: all 0.15s ease; }
                    .btn:hover { background: var(--clr-bg-dark); }
                    .btn.primary { background: var(--clr-primary-base); color:var(--clr-highlight); border-color: var(--clr-primary-base); }
                    .btn.primary:hover { background: var(--clr-primary-light); }
                </style>
                <div class="diagnostics-container">
                    <button class="refresh-btn btn primary">Refresh Diagnostics</button>
                    <div id="diagnostics-content">
                        <div class="loading">Loading diagnostics...</div>
                    </div>
                </div>
            `;

            this.shadowRoot.querySelector('.refresh-btn').addEventListener('click', () => this.refresh());
            this.refresh();
        }

        async refresh() {
            try {
                await whenApiClientReady();
                const response = await window.apiClient.admin.getDiagnostics();
                this._diagnostics = response.data || response;
                this.render();
            } catch (error) {
                console.error('Failed to load diagnostics:', error);
                this.shadowRoot.querySelector('#diagnostics-content').innerHTML = `<div style="padding:40px;text-align:center;color:var(--clr-danger);">Error loading diagnostics: ${error.message}</div>`;
            }
        }

        render() {
            if (!this._diagnostics) return;

            const d = this._diagnostics;
            let html = '';

            // Helper function to render a section table
            const renderSection = (title, data) => {
                if (!data || Object.keys(data).length === 0) return '';
                const rows = Object.entries(data).map(([key, value]) => 
                    `<tr><td class="param">${key}</td><td class="value">${value}</td></tr>`
                ).join('');
                return `
                    <div class="section">
                        <div class="section-title">${title}</div>
                        <table class="diagnostics-table">
                            <tbody>${rows}</tbody>
                        </table>
                    </div>
                `;
            };

            html += renderSection('Server Configuration', d.server);
            html += renderSection('OIDC Configuration', d.oidc);
            html += renderSection('Session Configuration', d.session);
            html += renderSection('Monitoring Configuration', d.monitoring);
            html += renderSection('Services', d.services);
            html += renderSection('Runtime Information', d.runtime);

            this.shadowRoot.querySelector('#diagnostics-content').innerHTML = html;
        }
    }

    if (!customElements.get('app-admin-diagnostics')) customElements.define('app-admin-diagnostics', AppAdminDiagnostics);
})();
