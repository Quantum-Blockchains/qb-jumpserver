// Jump Server - Web Components (native Custom Elements)
// Base service card + HTTP/SSH specializations and a simple modal

(function(){
    // Utilities
    function createTemplate(html) {
        const tpl = document.createElement('template');
        tpl.innerHTML = html.trim();
        return tpl;
    }

    // Service Status modal
    class AppServiceStatusModal extends HTMLElement {
        constructor(){
            super();
            this.attachShadow({ mode: 'open' });
            this._data = null;
            this._serviceData = null;
            this._tpl = createTemplate(`
                <style>
                    :host { position: fixed; inset:0; display:none; align-items:center; justify-content:center; background: rgba(0,0,0,.3); z-index: 9999; }
                    :host(.open) { display:flex; }
                    .modal { background: var(--clr-bg-highlight); border-radius: var(--radius-lg); width: min(700px, 95vw); max-height: 90vh; box-shadow: var(--shadow-xl); border:1px solid var(--clr-border-muted); display: flex; flex-direction: column; }
                    .header { display:flex; align-items:center; justify-content:space-between; padding:16px 20px; border-bottom:1px solid var(--clr-border); }
                    .header-title { display: flex; align-items: center; gap: 8px; font-size: 16px; font-weight: 600; }
                    .body { padding: 20px; overflow:auto; flex: 1; }
                    .section { margin-bottom: 20px; }
                    .section-title { font-weight: 600; font-size: 14px; margin-bottom: 8px; color: var(--clr-text-high); }
                    .status-grid { display: grid; gap: 12px; }
                    .status-card { background: var(--clr-bg-dark); border:1px solid var(--clr-border-muted); border-radius: var(--radius-md); padding: 12px; }
                    .status-card-header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 8px; }
                    .status-card-title { font-weight: 600; font-size: 13px; }
                    .status-indicator { display: inline-flex; align-items: center; gap: 6px; font-size: 12px; padding: 4px 8px; border-radius: var(--radius-sm); }
                    .status-indicator.healthy { background: rgba(34, 197, 94, 0.1); color: #22c55e; }
                    .status-indicator.degraded { background: rgba(245, 158, 11, 0.1); color: #f59e0b; }
                    .status-indicator.error { background: rgba(239, 68, 68, 0.1); color: #ef4444; }
                    .status-indicator.unreachable { background: rgba(107, 114, 128, 0.1); color: #6b7280; }
                    .metric-row { display: flex; justify-content: space-between; padding: 6px 0; font-size: 13px; border-bottom: 1px solid var(--clr-border-muted); }
                    .metric-row:last-child { border-bottom: none; }
                    .metric-label { color: var(--clr-text-muted); }
                    .metric-value { color: var(--clr-text-high); font-weight: 500; }
                    .footer { padding:12px 20px; display:flex; justify-content:flex-end; gap: 8px; border-top:1px solid var(--clr-border); }
                    .btn { border:1px solid var(--clr-border); background: var(--clr-bg-highlight); padding:6px 12px; border-radius: var(--radius-md); cursor:pointer; color: var(--clr-text-high); font-size:13px; }
                    .btn:hover { background: var(--clr-bg-dark); }
                    .btn.primary { background: var(--clr-primary-base); color: var(--clr-highlight); border-color: var(--clr-primary-base); }
                    .btn.primary:hover { background: var(--clr-primary-dark); }
                    .btn-small { border:1px solid var(--clr-border); background: var(--clr-bg-dark); padding:4px 8px; border-radius: var(--radius-sm); cursor:pointer; color: var(--clr-text-high); font-size:11px; }
                    .btn-small:hover { background: var(--clr-bg-highlight); }
                    .loading { text-align: center; padding: 40px; color: var(--clr-text-muted); }
                    .error-message { padding: 12px; background: rgba(239, 68, 68, 0.1); color: #ef4444; border-radius: var(--radius-md); margin-bottom: 12px; }
                    .logs-container { max-height: 300px; overflow-y: auto; background: var(--clr-bg-dark); border: 1px solid var(--clr-border-muted); border-radius: var(--radius-sm); padding: 8px; }
                </style>
                <div class="modal">
                    <div class="header">
                        <div class="header-title">
                            <span id="service-name">Service Status</span>
                        </div>
                        <button class="btn close">×</button>
                    </div>
                    <div class="body" id="modal-body">
                        <div class="loading">Loading status...</div>
                    </div>
                    <div class="footer">
                        <button class="btn" id="dump-btn">Dump Full Status</button>
                        <button class="btn" id="refresh-btn">Refresh</button>
                        <button class="btn close">Close</button>
                    </div>
                </div>
            `);
        }
        connectedCallback(){ 
            const r=this.shadowRoot; 
            if (!r.firstChild) r.appendChild(this._tpl.content.cloneNode(true)); 
            this._wire(); 
        }
        _wire(){ 
            const r=this.shadowRoot; 
            r.querySelectorAll('.btn.close').forEach(b=> b.addEventListener('click', ()=> this.close())); 
            const refreshBtn = r.getElementById('refresh-btn');
            refreshBtn && refreshBtn.addEventListener('click', ()=> this._refresh());
            const dumpBtn = r.getElementById('dump-btn');
            dumpBtn && dumpBtn.addEventListener('click', ()=> this._dumpStatus());
        }
        async open(serviceData){ 
            this._serviceData = serviceData || {};
            const r=this.shadowRoot; 
            if (!r.firstChild) r.appendChild(this._tpl.content.cloneNode(true));
            
            const nameEl = r.getElementById('service-name');
            if (nameEl) nameEl.textContent = (this._serviceData.name || this._serviceData.id || 'Service') + ' - Status';
            
            this.classList.add('open'); 
            this._bindEsc();
            await this._loadStatus();
        }
        async _refresh() {
            await this._loadStatus();
        }
        async _loadStatus() {
            const r = this.shadowRoot;
            const body = r.getElementById('modal-body');
            if (!body) return;
            
            body.innerHTML = '<div class="loading">Loading status...</div>';
            
            try {
                await whenApiClientReady();
                const serviceType = this._serviceData.type || 'http';
                
                if (serviceType === 'http') {
                    const result = await window.apiClient.services.http.getHealth(this._serviceData.id);
                    if (result && result.success && result.data) {
                        this._data = result.data; // Store for dumping
                        this._renderHttpStatus(result.data);
                    } else {
                        body.innerHTML = '<div class="error-message">Failed to load service status</div>';
                    }
                } else if (serviceType === 'ssh') {
                    const result = await window.apiClient.services.ssh.getStatus(this._serviceData.id);
                    if (result && result.success && result.data) {
                        this._data = result.data; // Store for dumping
                        this._renderSshStatus(result.data);
                    } else {
                        body.innerHTML = '<div class="error-message">Failed to load service status</div>';
                    }
                }
            } catch (e) {
                body.innerHTML = '<div class="error-message">Error loading status: ' + (e.message || 'Unknown error') + '</div>';
            }
        }
        _renderHttpStatus(data) {
            const r = this.shadowRoot;
            const body = r.getElementById('modal-body');
            if (!body) return;
            
            const overallStatus = data.overall_status || 'unknown';
            const statusClass = this._getStatusClass(overallStatus);
            const statusText = this._getStatusText(overallStatus);
            const statusIcon = this._getStatusIcon(overallStatus);
            
            let html = `
                <div class="section">
                    <div class="section-title">Overall Status</div>
                    <div class="status-card">
                        <div class="status-card-header">
                            <span class="status-indicator ${statusClass}">${statusIcon} ${statusText}</span>
                            <span style="font-size: 12px; color: var(--clr-text-muted);">Last checked: ${new Date(data.checked_at * 1000).toLocaleString()}</span>
                        </div>
                    </div>
                </div>
            `;
            
            // Show issues if any
            if (data.issues && data.issues.length > 0) {
                html += `
                    <div class="section">
                        <div class="section-title" style="color: #ef4444;">⚠ Compatibility Issues</div>
                        <div class="status-card" style="border-left: 3px solid #ef4444;">
                `;
                data.issues.forEach(issue => {
                    html += `
                        <div class="metric-row">
                            <span class="metric-value" style="color: #ef4444;">✕ ${issue}</span>
                        </div>
                    `;
                });
                html += `
                        </div>
                    </div>
                `;
            }
            
            // Show warnings if any
            if (data.warnings && data.warnings.length > 0) {
                html += `
                    <div class="section">
                        <div class="section-title" style="color: #f59e0b;">⚠ Compatibility Warnings</div>
                        <div class="status-card" style="border-left: 3px solid #f59e0b;">
                `;
                data.warnings.forEach(warning => {
                    html += `
                        <div class="metric-row">
                            <span class="metric-value" style="color: #f59e0b;">⚠ ${warning}</span>
                        </div>
                    `;
                });
                html += `
                        </div>
                    </div>
                `;
            }
            
            if (data.target) {
                const targetStatus = this._getStatusClass(data.target.status);
                const targetText = this._getStatusText(data.target.status);
                const targetIcon = this._getStatusIcon(data.target.status);
                
                html += `
                    <div class="section">
                        <div class="section-title">Target Service</div>
                        <div class="status-card">
                            <div class="status-card-header">
                                <span class="status-card-title">Direct Connection</span>
                                <span class="status-indicator ${targetStatus}">${targetIcon} ${targetText}</span>
                            </div>
                            <div class="metric-row">
                                <span class="metric-label">Reachable</span>
                                <span class="metric-value">${data.target.reachable ? '✓ Yes' : '✗ No'}</span>
                            </div>
                            <div class="metric-row">
                                <span class="metric-label">Response Time</span>
                                <span class="metric-value">${data.target.response_time_ms}ms</span>
                            </div>
                            ${data.target.http_status ? `<div class="metric-row">
                                <span class="metric-label">HTTP Status</span>
                                <span class="metric-value">${data.target.http_status}</span>
                            </div>` : ''}
                            ${data.target.error ? `<div class="metric-row">
                                <span class="metric-label">Error</span>
                                <span class="metric-value" style="color: #ef4444;">${data.target.error}</span>
                            </div>` : ''}
                        </div>
                    </div>
                `;
            }
            
            if (data.proxy) {
                const proxyStatus = this._getStatusClass(data.proxy.status);
                const proxyText = this._getStatusText(data.proxy.status);
                const proxyIcon = this._getStatusIcon(data.proxy.status);
                
                html += `
                    <div class="section">
                        <div class="section-title">Proxy Connection</div>
                        <div class="status-card">
                            <div class="status-card-header">
                                <span class="status-card-title">Jump Server Proxy</span>
                                <span class="status-indicator ${proxyStatus}">${proxyIcon} ${proxyText}</span>
                            </div>
                            <div class="metric-row">
                                <span class="metric-label">Proxy Working</span>
                                <span class="metric-value">${data.proxy.working ? '✓ Yes' : '✗ No'}</span>
                            </div>
                            <div class="metric-row">
                                <span class="metric-label">Response Time</span>
                                <span class="metric-value">${data.proxy.response_time_ms}ms</span>
                            </div>
                            ${data.proxy.http_status ? `<div class="metric-row">
                                <span class="metric-label">Final HTTP Status</span>
                                <span class="metric-value">${data.proxy.http_status}</span>
                            </div>` : ''}
                            ${data.proxy.redirect_count !== undefined ? `<div class="metric-row">
                                <span class="metric-label">Redirects Followed</span>
                                <span class="metric-value">${data.proxy.redirect_count}</span>
                            </div>` : ''}
                            ${data.proxy.error ? `<div class="metric-row">
                                <span class="metric-label">Error</span>
                                <span class="metric-value" style="color: #ef4444;">${data.proxy.error}</span>
                            </div>` : ''}
                        </div>
                    </div>
                `;
                
                // Store redirect chain HTML for later (will be in dropdown)
                let redirectChainHtml = '';
                if (data.proxy.redirect_chain && data.proxy.redirect_chain.length > 0) {
                    data.proxy.redirect_chain.forEach((step, idx) => {
                        const stepStatus = step.status;
                        const stepClass = stepStatus >= 200 && stepStatus < 300 ? 'healthy' : 
                                         stepStatus >= 300 && stepStatus < 400 ? 'degraded' : 'error';
                        
                        const location = step.headers && (step.headers.Location || step.headers.location);
                        const isRedirect = stepStatus >= 300 && stepStatus < 400;
                        
                        redirectChainHtml += `
                            <div style="padding: 12px; border-bottom: 1px solid var(--clr-border-muted); background: var(--clr-bg-dark); margin: 8px 0;">
                                <div style="margin-bottom: 8px;">
                                    <span style="font-weight: 600;">Step ${step.step || idx + 1}</span>
                                    <span class="status-indicator ${stepClass}" style="display: inline-flex; padding: 2px 6px; margin-left: 8px;">${stepStatus}</span>
                                </div>
                                <div style="font-size: 11px; color: var(--clr-text-muted); margin-bottom: 4px; word-break: break-all;">
                                    <strong>URL:</strong> ${step.url}
                                </div>
                                ${isRedirect && location ? `
                                    <div style="font-size: 11px; margin-top: 8px; padding: 8px; background: var(--clr-bg-highlight); border-radius: 4px; border-left: 3px solid ${location.includes('192.168') || location.includes(':808') ? '#ef4444' : '#22c55e'};">
                                        <div style="color: var(--clr-text-muted); margin-bottom: 4px;"><strong>Location Header:</strong></div>
                                        <div style="color: ${location.includes('192.168') || location.includes(':808') ? '#ef4444' : '#22c55e'}; font-family: monospace; word-break: break-all;">
                                            ${location}
                                        </div>
                                        ${location.includes('192.168') || location.includes(':808') ? 
                                            '<div style="color: #ef4444; margin-top: 4px; font-weight: 600;">⚠ LEAKED - Exposes backend IP!</div>' : 
                                            '<div style="color: #22c55e; margin-top: 4px; font-weight: 600;">✓ REWRITTEN - Stays in proxy path</div>'
                                        }
                                    </div>
                                ` : ''}
                            </div>
                        `;
                    });
                }
                
                // Proxy issues (if any)
                if (data.proxy.proxy_issues && data.proxy.proxy_issues.length > 0) {
                    html += `
                        <div class="section">
                            <div class="section-title" style="color: #ef4444;">⚠ Proxy Issues Detected</div>
                            <div class="status-card" style="border-left: 3px solid #ef4444;">
                    `;
                    data.proxy.proxy_issues.forEach(issue => {
                        html += `
                            <div class="metric-row">
                                <span class="metric-value" style="color: #ef4444;">✕ ${issue}</span>
                            </div>
                        `;
                    });
                    html += `
                            </div>
                        </div>
                    `;
                }
                
                // Generate cookie examples HTML
                let cookieExamplesHtml = '';
                if (data.proxy.redirect_chain && data.proxy.redirect_chain.length > 0) {
                    const cookieExamples = [];
                    data.proxy.redirect_chain.forEach((step, idx) => {
                        const setCookie = step.headers && (step.headers['Set-Cookie'] || step.headers['set-cookie']);
                        if (setCookie) {
                            const cookies = Array.isArray(setCookie) ? setCookie : [setCookie];
                            cookies.forEach(cookie => {
                                const pathMatch = cookie.match(/Path=([^;]+)/i);
                                if (pathMatch) {
                                    cookieExamples.push({
                                        step: step.step || (idx + 1),
                                        cookie: cookie.substring(0, 150) + (cookie.length > 150 ? '...' : ''),
                                        path: pathMatch[1],
                                        correct: pathMatch[1].startsWith('/http/')
                                    });
                                }
                            });
                        }
                    });
                    
                    if (cookieExamples.length > 0) {
                        cookieExamples.forEach(example => {
                            const color = example.correct ? '#22c55e' : '#f59e0b';
                            const status = example.correct ? '✓ Correct' : '⚠ Wrong';
                            cookieExamplesHtml += `
                                <div style="padding: 12px; border-bottom: 1px solid var(--clr-border-muted); background: var(--clr-bg-dark); margin: 8px 0;">
                                    <div style="margin-bottom: 8px;">
                                        <span style="font-weight: 600;">Step ${example.step}</span>
                                        <span style="color: ${color}; font-weight: 600; margin-left: 8px;">${status}</span>
                                    </div>
                                    <div style="font-size: 11px; padding: 8px; background: var(--clr-bg-highlight); border-radius: 4px; font-family: monospace; word-break: break-all; border-left: 3px solid ${color};">
                                        <div style="color: var(--clr-text-muted); margin-bottom: 4px;">Set-Cookie:</div>
                                        <div style="color: var(--clr-text-high);">${example.cookie}</div>
                                        <div style="color: ${color}; margin-top: 8px; font-weight: 600;">
                                            Path = ${example.path}
                                            ${example.correct ? ' ✓ Scoped to proxy path' : ' ⚠ Not scoped to proxy'}
                                        </div>
                                    </div>
                                </div>
                            `;
                        });
                    }
                }
                
                // Proxy verification with collapsible sections
                if (data.proxy.proxy_verification) {
                    const verify = data.proxy.proxy_verification;
                    const redirectId = 'redirects-' + Math.random().toString(36).substr(2, 9);
                    const cookieId = 'cookies-' + Math.random().toString(36).substr(2, 9);
                    
                    html += `
                        <div class="section">
                            <div class="section-title">Proxy Verification</div>
                            <div class="status-card">
                                <div class="metric-row" style="cursor: ${redirectChainHtml ? 'pointer' : 'default'};" onclick="${redirectChainHtml ? `this.nextElementSibling.style.display = this.nextElementSibling.style.display === 'none' ? 'block' : 'none'; this.querySelector('.chevron').textContent = this.nextElementSibling.style.display === 'none' ? '▶' : '▼'` : ''}">
                                    <span class="metric-label">
                                        ${redirectChainHtml ? '<span class="chevron" style="display: inline-block; width: 12px;">▶</span> ' : ''}
                                        Redirects Followed
                                    </span>
                                    <span class="metric-value">${verify.redirects_followed ? '✓ Yes (' + verify.redirect_count + ' redirects)' : '✗ No'}</span>
                                </div>
                                ${redirectChainHtml ? `<div style="display: none; margin-top: 8px;">${redirectChainHtml}</div>` : ''}
                                
                                <div class="metric-row">
                                    <span class="metric-label">Redirects Stayed Internal</span>
                                    <span class="metric-value" style="color: ${verify.redirects_stayed_internal ? 'var(--clr-success)' : '#ef4444'}">
                                        ${verify.redirects_stayed_internal ? '✓ Yes' : '✗ No (CRITICAL)'}
                                    </span>
                                </div>
                                
                                <div class="metric-row" style="cursor: ${cookieExamplesHtml ? 'pointer' : 'default'};" onclick="${cookieExamplesHtml ? `this.nextElementSibling.style.display = this.nextElementSibling.style.display === 'none' ? 'block' : 'none'; this.querySelector('.chevron').textContent = this.nextElementSibling.style.display === 'none' ? '▶' : '▼'` : ''}">
                                    <span class="metric-label">
                                        ${cookieExamplesHtml ? '<span class="chevron" style="display: inline-block; width: 12px;">▶</span> ' : ''}
                                        Cookie Paths Correct
                                    </span>
                                    <span class="metric-value" style="color: ${verify.cookie_paths_correct ? 'var(--clr-success)' : '#f59e0b'}">
                                        ${verify.cookie_paths_correct ? '✓ Yes' : '✗ No'}
                                    </span>
                                </div>
                                ${cookieExamplesHtml ? `<div style="display: none; margin-top: 8px;">${cookieExamplesHtml}</div>` : ''}
                                
                                <div class="metric-row">
                                    <span class="metric-label">URL Rewriting Working</span>
                                    <span class="metric-value" style="color: ${verify.url_rewriting_working ? 'var(--clr-success)' : '#ef4444'}; font-weight: 600;">
                                        ${verify.url_rewriting_working ? '✓ YES' : '✗ NO'}
                                    </span>
                                </div>
                                
                                <div class="metric-row">
                                    <span class="metric-label">Final URL Reachable</span>
                                    <span class="metric-value">${verify.final_url_reachable ? '✓ Yes' : '✗ No'}</span>
                                </div>
                            </div>
                        </div>
                    `;
                    
                    // Display leaked URLs if any
                    if (verify.leaked_urls && verify.leaked_urls.length > 0) {
                        html += `
                            <div class="section">
                                <div class="section-title" style="color: #ef4444;">⚠ Leaked URLs (Exposed Backend)</div>
                                <div class="status-card" style="border-left: 3px solid #ef4444;">
                        `;
                        verify.leaked_urls.forEach(url => {
                            html += `
                                <div class="metric-row">
                                    <span class="metric-value" style="font-size: 11px; color: #ef4444; word-break: break-all;">${url}</span>
                                </div>
                            `;
                        });
                        html += `
                                </div>
                            </div>
                        `;
                    }
                }
                
                // Advanced Checks - simplified
                if (data.advanced_checks) {
                    const adv = data.advanced_checks;
                    
                    // Check if there's anything to show
                    const hasContentIssues = adv.content_scan && adv.content_scan.scanned && 
                                           ((adv.content_scan.issues && adv.content_scan.issues.length > 0) ||
                                            (adv.content_scan.warnings && adv.content_scan.warnings.length > 0) ||
                                            (adv.content_scan.spa_frameworks && adv.content_scan.spa_frameworks.length > 0));
                    
                    if (hasContentIssues) {
                        html += `
                            <div class="section">
                                <div class="section-title">Advanced Diagnostics</div>
                                <div class="status-card">
                        `;
                        
                        // Content Scan Results - only show if there are issues
                        if (hasContentIssues) {
                            const scan = adv.content_scan;
                            
                            if (scan.spa_frameworks && scan.spa_frameworks.length > 0) {
                                html += `
                                    <div class="metric-row">
                                        <span class="metric-label">SPA Framework Detected</span>
                                        <span class="metric-value" style="color: #f59e0b;">
                                            ${scan.spa_frameworks.join(', ')}
                                        </span>
                                    </div>
                                `;
                            }
                            
                            // Show specific issues found in content
                            if (scan.issues && scan.issues.length > 0) {
                                html += `
                                    <div class="metric-row" style="display: block; margin-top: 8px;">
                                        <span class="metric-label" style="color: #ef4444;">Content Issues:</span>
                                        <div style="margin-top: 8px; padding: 8px; background: rgba(239, 68, 68, 0.1); border-radius: 4px; border-left: 3px solid #ef4444;">
                                `;
                                scan.issues.forEach(issue => {
                                    html += `
                                        <div style="font-size: 11px; color: #ef4444; margin: 4px 0;">
                                            ✕ ${issue}
                                        </div>
                                    `;
                                });
                                html += `
                                        </div>
                                    </div>
                                `;
                            }
                            
                            if (scan.warnings && scan.warnings.length > 0) {
                                html += `
                                    <div class="metric-row" style="display: block; margin-top: 8px;">
                                        <span class="metric-label" style="color: #f59e0b;">Content Warnings:</span>
                                        <div style="margin-top: 8px; padding: 8px; background: rgba(245, 158, 11, 0.1); border-radius: 4px; border-left: 3px solid #f59e0b;">
                                `;
                                scan.warnings.forEach(warning => {
                                    html += `
                                        <div style="font-size: 11px; color: #f59e0b; margin: 4px 0;">
                                            ⚠ ${warning}
                                        </div>
                                    `;
                                });
                                html += `
                                        </div>
                                    </div>
                                `;
                            }
                        }
                        
                        html += `
                                </div>
                            </div>
                        `;
                    }
                }
            }
            
            // Logs section
            if (data.proxy && data.proxy.logs && data.proxy.logs.length > 0) {
                html += `
                    <div class="section">
                        <div class="section-title" style="display: flex; justify-content: space-between; align-items: center;">
                            <span>Status Logs</span>
                            <button class="btn-small" onclick="this.getRootNode().host._copyLogs('proxy')">Copy Logs</button>
                        </div>
                        <div class="status-card">
                            <div class="logs-container" id="proxy-logs">
                                <pre style="margin: 0; font-size: 11px; line-height: 1.4; color: var(--clr-text-high); white-space: pre-wrap; word-break: break-word;">${data.proxy.logs.join('\n')}</pre>
                            </div>
                        </div>
                    </div>
                `;
            }
            
            body.innerHTML = html;
        }
        _renderSshStatus(data) {
            const r = this.shadowRoot;
            const body = r.getElementById('modal-body');
            if (!body) return;
            
            const status = data.status || 'unknown';
            const statusClass = this._getStatusClass(status);
            const statusText = this._getStatusText(status);
            const statusIcon = this._getStatusIcon(status);
            
            let html = `
                <div class="section">
                    <div class="section-title">SSH Service Status</div>
                    <div class="status-card">
                        <div class="status-card-header">
                            <span class="status-indicator ${statusClass}">${statusIcon} ${statusText}</span>
                            <span style="font-size: 12px; color: var(--clr-text-muted);">Last checked: ${new Date(data.checked_at * 1000).toLocaleString()}</span>
                        </div>
                        <div class="metric-row">
                            <span class="metric-label">Reachable</span>
                            <span class="metric-value">${data.reachable ? '✓ Yes' : '✗ No'}</span>
                        </div>
                        <div class="metric-row">
                            <span class="metric-label">Response Time</span>
                            <span class="metric-value">${data.response_time_ms}ms</span>
                        </div>
                        ${data.banner ? `<div class="metric-row">
                            <span class="metric-label">SSH Banner</span>
                            <span class="metric-value" style="font-size: 11px;">${data.banner}</span>
                        </div>` : ''}
                        ${data.error ? `<div class="metric-row">
                            <span class="metric-label">Error</span>
                            <span class="metric-value" style="color: #ef4444;">${data.error}</span>
                        </div>` : ''}
                    </div>
                </div>
            `;
            
            body.innerHTML = html;
        }
        _getStatusClass(status) {
            const classMap = {
                'healthy': 'healthy',
                'degraded': 'degraded',
                'error': 'error',
                'unreachable': 'unreachable',
                'proxy_error': 'error',
                'proxy_healthy': 'healthy',
                'proxy_degraded': 'degraded',
                'proxy_auth_required': 'healthy',
                'proxy_rewrite_broken': 'error'
            };
            return classMap[status] || 'unreachable';
        }
        _getStatusText(status) {
            const statusMap = {
                'healthy': 'Healthy',
                'degraded': 'Degraded',
                'error': 'Error',
                'unreachable': 'Unreachable',
                'proxy_error': 'Proxy Error',
                'proxy_healthy': 'Healthy',
                'proxy_degraded': 'Degraded',
                'proxy_auth_required': 'Auth Required',
                'proxy_rewrite_broken': 'URL Rewrite Broken'
            };
            return statusMap[status] || 'Unknown';
        }
        _getStatusIcon(status) {
            const iconMap = {
                'healthy': '●',
                'degraded': '◐',
                'error': '✕',
                'unreachable': '○',
                'proxy_error': '✕',
                'proxy_healthy': '●',
                'proxy_degraded': '◐',
                'proxy_auth_required': '●'
            };
            return iconMap[status] || '?';
        }
        _truncateUrl(url, maxLength) {
            if (!url || url.length <= maxLength) return url;
            const start = Math.floor(maxLength * 0.4);
            const end = Math.floor(maxLength * 0.4);
            return url.substring(0, start) + '...' + url.substring(url.length - end);
        }
        async _copyLogs(type) {
            try {
                const r = this.shadowRoot;
                const logsEl = r.getElementById(type + '-logs');
                if (!logsEl) return;
                
                const logsText = logsEl.textContent || '';
                
                // Try modern clipboard API first
                if (navigator.clipboard && navigator.clipboard.writeText) {
                    await navigator.clipboard.writeText(logsText);
                    if (window.notifications) {
                        window.notifications.success('Logs copied to clipboard');
                    }
                } else {
                    // Fallback for older browsers
                    const ta = document.createElement('textarea');
                    ta.value = logsText;
                    ta.style.position = 'fixed';
                    ta.style.left = '-9999px';
                    document.body.appendChild(ta);
                    ta.select();
                    document.execCommand('copy');
                    document.body.removeChild(ta);
                    if (window.notifications) {
                        window.notifications.success('Logs copied to clipboard');
                    }
                }
            } catch (e) {
                console.error('Failed to copy logs:', e);
                if (window.notifications) {
                    window.notifications.error('Failed to copy logs');
                }
            }
        }
        _dumpStatus() {
            if (!this._data) {
                if (window.notifications) {
                    window.notifications.error('No status data available');
                }
                return;
            }
            
            try {
                const timestamp = new Date().toISOString().replace(/[:.]/g, '-').substring(0, 19);
                const serviceId = this._serviceData?.id || 'unknown';
                const filename = `status-${serviceId}-${timestamp}.json`;
                
                const statusData = {
                    service: this._serviceData,
                    status: this._data,
                    exported_at: new Date().toISOString(),
                    exported_by: 'JumpServer Status Monitor'
                };
                
                const jsonStr = JSON.stringify(statusData, null, 2);
                const blob = new Blob([jsonStr], { type: 'application/json' });
                const url = URL.createObjectURL(blob);
                
                const a = document.createElement('a');
                a.href = url;
                a.download = filename;
                a.style.display = 'none';
                document.body.appendChild(a);
                a.click();
                document.body.removeChild(a);
                URL.revokeObjectURL(url);
                
                if (window.notifications) {
                    window.notifications.success('Status dumped to ' + filename);
                }
            } catch (e) {
                console.error('Failed to dump status:', e);
                if (window.notifications) {
                    window.notifications.error('Failed to dump status');
                }
            }
        }
        close(){ this.classList.remove('open'); this._unbindEsc(); }
        _bindEsc(){ if (this._escBound) return; this._escHandler = (e)=>{ if (e && (e.key === 'Escape' || e.key === 'Esc')) { e.preventDefault(); this.close(); } }; window.addEventListener('keydown', this._escHandler, true); this._escBound = true; }
        _unbindEsc(){ if (!this._escBound) return; window.removeEventListener('keydown', this._escHandler, true); this._escBound = false; this._escHandler = null; }
    }

    // Diagnostics modal (safe info)
    class AppDiagnosticsModal extends HTMLElement {
        constructor(){
            super();
            this.attachShadow({ mode: 'open' });
            this._data = null;
            this._tpl = createTemplate(`
                <style>
                    :host { position: fixed; inset:0; display:none; align-items:center; justify-content:center; background: rgba(0,0,0,.3); z-index: 9999; }
                    :host(.open) { display:flex; }
                    .modal { background: var(--clr-bg-highlight); border-radius: var(--radius-lg); width: min(600px, 95vw); box-shadow: var(--shadow-xl); border:1px solid var(--clr-border-muted); }
                    .header { display:flex; align-items:center; justify-content:space-between; padding:12px 16px; border-bottom:1px solid var(--clr-border); }
                    .body { padding: 12px 16px; max-height: 70vh; overflow:auto; }
                    .details-content { background: var(--clr-bg-dark); border:1px solid var(--clr-border-muted); border-radius: var(--radius-md); padding: 8px; margin-top: 6px; max-height: 60vh; overflow: auto; }
                    pre { margin: 0; background: var(--clr-bg-dark); color: var(--clr-text-high); padding: 0; border-radius: var(--radius-md); white-space: pre-wrap; word-break: break-word; }
                    .footer { padding:12px 16px; display:flex; justify-content:flex-end; border-top:1px solid var(--clr-border); }
                    .btn { border:1px solid var(--clr-border); background: var(--clr-bg-highlight); padding:6px 10px; border-radius: var(--radius-md); cursor:pointer; color: var(--clr-text-high); font-size:13px; }
                    .btn:hover { background: var(--clr-bg-dark); }
                </style>
                <div class="modal">
                    <div class="header"><div>Diagnostics</div><div><button class="btn copy">Copy</button> <button class="btn close">×</button></div></div>
                    <div class="body"><div class="details-content"><pre id="content"></pre></div></div>
                    <div class="footer"><button class="btn close">Close</button></div>
                </div>
            `);
        }
        connectedCallback(){ const r=this.shadowRoot; if (!r.firstChild) r.appendChild(this._tpl.content.cloneNode(true)); this._wire(); }
        _wire(){ const r=this.shadowRoot; r.querySelectorAll('.btn.close').forEach(b=> b.addEventListener('click', ()=> this.close())); const copyBtn = r.querySelector('.btn.copy'); copyBtn && copyBtn.addEventListener('click', ()=> this._copy()); }
        async _copy(){ try { const r=this.shadowRoot; const pre=r && r.getElementById('content'); const text = pre ? pre.textContent : ''; await (navigator.clipboard && navigator.clipboard.writeText ? navigator.clipboard.writeText(text||'') : Promise.reject(new Error('clipboard'))); if (window.notifications) notifications.success('Diagnostics copied'); } catch (_) { try { const ta = document.createElement('textarea'); ta.value = (this._data && JSON.stringify(this._data, null, 2)) || ''; document.body.appendChild(ta); ta.select(); document.execCommand('copy'); document.body.removeChild(ta); if (window.notifications) notifications.success('Diagnostics copied'); } catch (e) { if (window.notifications) notifications.error('Copy failed'); } } }
        open(data){ this._data = data || {}; const r=this.shadowRoot; if (!r.firstChild) r.appendChild(this._tpl.content.cloneNode(true)); const pre=r.getElementById('content'); pre.textContent = JSON.stringify(this._data, null, 2); this.classList.add('open'); this._bindEsc(); }
        close(){ this.classList.remove('open'); this._unbindEsc(); }
        _bindEsc(){ if (this._escBound) return; this._escHandler = (e)=>{ if (e && (e.key === 'Escape' || e.key === 'Esc')) { e.preventDefault(); this.close(); } }; window.addEventListener('keydown', this._escHandler, true); this._escBound = true; }
        _unbindEsc(){ if (!this._escBound) return; window.removeEventListener('keydown', this._escHandler, true); this._escBound = false; this._escHandler = null; }
    }

    function formatUrl(service) {
        if (service && service.url) return service.url;
        if (!service) return '';
        if (service.protocol && service.host && service.port) {
            const path = service.path || '/';
            return `${service.protocol}://${service.host}:${service.port}${path}`;
        }
        return '';
    }

    // Wait for apiClient
    async function whenApiClientReady(maxWaitMs = 10000) {
        const started = Date.now();
        while (!window.apiClient) {
            if (Date.now() - started > maxWaitMs) throw new Error('apiClient not ready');
            await new Promise(r => setTimeout(r, 50));
        }
    }

    // Header component
    class AppHeader extends HTMLElement {
        constructor() {
            super();
            this.attachShadow({ mode: 'open' });
            this._rootTpl = createTemplate(`
                <style>
                    .header { border-bottom:1px solid var(--clr-border); background:var(--clr-bg-highlight); }
                    .content { display:flex; align-items:center; justify-content:space-between; max-width: var(--container-xl); margin: 0 auto; padding: var(--spacing-lg); }
                    .logo a { text-decoration:none;color:var(--clr-text-high);font-weight:700; }
                    .nav-list { display:flex;gap:12px;list-style:none;margin:0;padding:0; }
                    .nav-link { text-decoration:none;color:var(--clr-text-muted);padding:6px 8px;border-radius: var(--radius-md); }
                    .nav-link.active { background: var(--clr-primary-base); color:var(--clr-highlight); }
                    .user { position:relative; display:flex;gap:8px;align-items:center; color: var(--clr-text-muted); cursor:pointer; }
                    .avatar { width:28px;height:28px;border-radius:999px;background: var(--clr-primary-dark);color:var(--clr-highlight);display:flex;align-items:center;justify-content:center;font-weight:700; }
                    .menu { position:absolute; right:0; top:calc(100% + 8px); background: var(--clr-bg-highlight); border:1px solid var(--clr-border-muted); border-radius: var(--radius-md); box-shadow: var(--shadow-lg); min-width: 160px; padding:4px; display:none; z-index: 10; }
                    .menu.open { display:block; }
                    .menu-item { display:flex; width:100%; border:0; background:transparent; color: var(--clr-text-high); text-align:left; padding:8px 10px; border-radius: var(--radius-sm); cursor:pointer; }
                    .menu-item:hover { background: var(--clr-bg-dark); }
                    .caret { width:0; height:0; border-left:4px solid transparent; border-right:4px solid transparent; border-top:6px solid var(--clr-text-muted); transition: transform .15s ease; }
                    #avatar[aria-expanded="true"] ~ .caret { transform: rotate(180deg); }
                </style>
                <div class="header">
                    <div class="content">
                        <div class="left">
                            <h1 class="logo"><a href="/dashboard" id="header-title">Jump Server</a></h1>
                        </div>
                        <div class="user" id="user-menu">
                            <div class="avatar" id="avatar" aria-haspopup="menu" aria-expanded="false">U</div>
                            <div class="name" id="name">User</div>
                            <div class="caret" aria-hidden="true"></div>
                            <div class="menu" id="user-dropdown" role="menu" aria-label="User menu">
                                <button class="menu-item" id="nav-admin" role="menuitem" hidden>Administration</button>
                                <button class="menu-item" id="nav-dashboard" role="menuitem" hidden>Dashboard</button>
                                <button class="menu-item" id="nav-oidc-admin" role="menuitem" hidden>OIDC Provider</button>
                                <button class="menu-item" id="diagnostics-btn" role="menuitem">Diagnostics</button>
                                <button class="menu-item" id="logout-btn" role="menuitem">Logout</button>
                            </div>
                        </div>
                    </div>
                </div>
            `);
        }
        connectedCallback() { this.render(); this._bindConfigSync(); }
        async render() {
            const root = this.shadowRoot;
            if (!root.firstChild) root.appendChild(this._rootTpl.content.cloneNode(true));
            try {
                await whenApiClientReady();
                
                // Update title from configuration (initial)
                const titleEl = root.getElementById('header-title');
                if (titleEl && window.__APP_CONFIG__ && window.__APP_CONFIG__.title) {
                    titleEl.textContent = window.__APP_CONFIG__.title;
                }
                
                const [session, perms] = await Promise.all([
                    window.apiClient.auth.getSession().catch(()=>null),
                    window.apiClient.auth.getPermissions().catch(()=>null)
                ]);
                const user = session && session.data && session.data.user;
                const display = (user && (user.name || user.email)) || 'User';
                const avatar = root.getElementById('avatar');
                const name = root.getElementById('name');
                if (avatar) avatar.textContent = (display||'U').toString().trim().charAt(0).toUpperCase();
                if (name) name.textContent = display;
                const isAdmin = !!(perms && perms.data && perms.data.is_admin === true);
                const onAdminPage = (this.getAttribute('active')||'').toLowerCase() === 'administration' || window.location.pathname === '/administration';
                const navAdmin = root.getElementById('nav-admin');
                const navDashboard = root.getElementById('nav-dashboard');
                const navOidcAdmin = root.getElementById('nav-oidc-admin');
                if (navAdmin) {
                    if (!isAdmin || onAdminPage) {
                        // Remove entirely to avoid any visibility glitches
                        navAdmin.remove();
                    } else {
                        navAdmin.hidden = false;
                        navAdmin.style.display = '';
                    }
                }
                if (navDashboard) {
                    navDashboard.hidden = !onAdminPage;
                    navDashboard.style.display = onAdminPage ? '' : 'none';
                }
                // Conditionally show OIDC Provider menu option for admins when enabled
                if (navOidcAdmin) {
                    try {
                        if (isAdmin && window.apiClient && window.apiClient.admin && window.apiClient.admin.getOIDCConfig) {
                            const cfgResp = await window.apiClient.admin.getOIDCConfig().catch(()=>null);
                            const data = cfgResp && cfgResp.data;
                            const show = !!(data && (data.show_oidc_menu === true));
                            const adminUrl = data && data.admin_url;
                            if (show && adminUrl) {
                                navOidcAdmin.hidden = false;
                                navOidcAdmin.style.display = '';
                                navOidcAdmin.dataset.href = adminUrl;
                            } else {
                                navOidcAdmin.remove();
                            }
                        } else {
                            navOidcAdmin.remove();
                        }
                    } catch (_) { navOidcAdmin.remove(); }
                }
            } catch (_) {}
            this._wireUserMenu();
        }
        _bindConfigSync(){
            if (this._cfgBound) return; this._cfgBound = true;
            const update = (cfg)=>{
                try {
                    const root = this.shadowRoot;
                    const titleEl = root && root.getElementById('header-title');
                    const title = (cfg && cfg.title) || (window.__APP_CONFIG__ && window.__APP_CONFIG__.title) || null;
                    if (titleEl && title) titleEl.textContent = title;
                } catch (_) {}
            };
            document.addEventListener('app:config-loaded', (e)=> update(e && e.detail && e.detail.config));
            // Apply immediately if config already present
            update(window.__APP_CONFIG__);
        }
        _wireUserMenu(){
            if (this._menuWired) return; this._menuWired = true;
            const root = this.shadowRoot;
            const userMenu = root.getElementById('user-menu');
            const dropdown = root.getElementById('user-dropdown');
            const avatar = root.getElementById('avatar');
            const logoutBtn = root.getElementById('logout-btn');
            const navAdmin = root.getElementById('nav-admin');
            const navDashboard = root.getElementById('nav-dashboard');
            const navOidcAdmin = root.getElementById('nav-oidc-admin');
            const diagnosticsBtn = root.getElementById('diagnostics-btn');
            const setOpen = (open)=>{
                dropdown && dropdown.classList.toggle('open', !!open);
                avatar && avatar.setAttribute('aria-expanded', open ? 'true' : 'false');
            };
            const toggle = (e)=>{ e && e.stopPropagation(); setOpen(!(dropdown && dropdown.classList.contains('open'))); };
            userMenu && userMenu.addEventListener('click', toggle);
            logoutBtn && logoutBtn.addEventListener('click', async (e)=>{
                e.stopPropagation();
                try { await window.apiClient.auth.logout(); window.location.href = '/login'; }
                catch (_) { window.location.href = '/auth/logout'; }
            });
            navAdmin && navAdmin.addEventListener('click', (e)=>{
                e.stopPropagation();
                try { window.location.href = '/administration'; } catch (_) {}
            });
            navDashboard && navDashboard.addEventListener('click', (e)=>{
                e.stopPropagation();
                try { window.location.href = '/dashboard'; } catch (_) {}
            });
            navOidcAdmin && navOidcAdmin.addEventListener('click', (e)=>{
                e.stopPropagation();
                const href = navOidcAdmin && navOidcAdmin.dataset && navOidcAdmin.dataset.href;
                if (href) {
                    try { window.open(href, '_blank'); } catch (_) { window.location.href = href; }
                }
            });
            diagnosticsBtn && diagnosticsBtn.addEventListener('click', async (e)=>{
                e.stopPropagation();
                await this._openDiagnostics();
            });
            const onDocClick = (e)=>{
                const path = e.composedPath && e.composedPath();
                const inside = path && path.includes(this);
                if (!inside) setOpen(false);
            };
            window.addEventListener('click', onDocClick, true);
            this._cleanup = ()=> window.removeEventListener('click', onDocClick, true);
        }
        async _openDiagnostics(){
            try {
                await whenApiClientReady();
                const [session, perms] = await Promise.all([
                    window.apiClient.auth.getSession().catch(()=>null),
                    window.apiClient.auth.getPermissions().catch(()=>null)
                ]);
                const safe = {
                    app: 'Jump Server',
                    location: window.location.pathname,
                    user: session && session.data && session.data.user ? { user_id: session.data.user.user_id, email: session.data.user.email, name: session.data.user.name } : null,
                    session: session && session.data && session.data.session ? session.data.session : null,
                    is_admin: !!(perms && (perms.data && perms.data.is_admin)),
                    roles: (perms && perms.data && Array.isArray(perms.data.roles)) ? perms.data.roles : []
                };
                const modal = document.querySelector('app-diagnostics-modal') || document.body.appendChild(document.createElement('app-diagnostics-modal'));
                modal.open(safe);
            } catch (e) {
                console.error('open diagnostics failed', e);
            }
        }
    }

    // Dashboard services component
    class AppDashboardServices extends HTMLElement {
        static get observedAttributes() { return ['type']; }
        
        constructor() {
            super();
            this.attachShadow({ mode: 'open' });
            this._type = 'http';
            this._rootTpl = createTemplate(`
                <style>
                    .panel { background:var(--clr-bg-highlight);border:1px solid var(--clr-border-muted);border-radius: var(--radius-lg);margin:12px 0; box-shadow: var(--shadow-sm); }
                    .panel-header { padding:16px 20px;display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid var(--clr-border); }
                    .panel-content { padding:16px 20px; }
                    .grid { display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap: var(--spacing-lg); }
                    .empty-state { padding: 8px 10px; color: var(--clr-text-muted); }
                </style>
                <section class="panel">
                    <div class="panel-header"><h2 id="title">Services</h2></div>
                    <div class="panel-content">
                        <div class="grid" id="grid"></div>
                        <div class="empty-state" id="empty" style="display:none;">No services available right now.</div>
                    </div>
                </section>
            `);
        }
        
        attributeChangedCallback(name, oldValue, newValue) {
            if (name !== 'type') return;
            if (oldValue === newValue) return;
            this._type = (newValue || 'http').toLowerCase();
            // Avoid double refresh on initial connect
            if (this._connectedOnce) this.refresh();
        }
        
        connectedCallback(){ 
            if (!this.shadowRoot.firstChild) { this.render(); this._wire(); } 
            this._connectedOnce = true;
            this.refresh(); 
        }
        
        _wire(){
            // No controls currently
        }
        async refresh(){
            if (this._isRefreshing) return;
            this._isRefreshing = true;
            try {
                await whenApiClientReady();
                const root = this.shadowRoot;
                if (!root.firstChild) root.appendChild(this._rootTpl.content.cloneNode(true));
                
                const title = root.getElementById('title');
                if (title) title.textContent = (this._type === 'ssh' ? 'SSH' : 'Web') + ' Services';
                
                const resp = (this._type === 'ssh') ? 
                    await window.apiClient.services.ssh.available() : 
                    await window.apiClient.services.http.available();
                    
                const list = (resp)=>{
                    const base = (resp && typeof resp === 'object' && 'data' in resp) ? resp.data : resp;
                    if (Array.isArray(base)) return base;
                    if (base && Array.isArray(base.services)) return base.services;
                    if (base && base.services && typeof base.services === 'object') return Object.values(base.services);
                    if (base && Array.isArray(base.data)) return base.data;
                    return [];
                };
                
                const services = list(resp).map(s => ({...s, type: this._type}));
                const byTitle = (a, b) => {
                    const an = String((a && (a.name || a.id)) || '');
                    const bn = String((b && (b.name || b.id)) || '');
                    return an.localeCompare(bn, undefined, { numeric: true, sensitivity: 'base' });
                };
                const sorted = services.slice().sort(byTitle);
                this._renderServices(sorted);
            } catch (e) {
                console.error('dashboard services load failed', e);
            } finally { this._isRefreshing = false; }
        }
        _renderServices(services){
            const root = this.shadowRoot;
            const grid = root.getElementById('grid');
            const empty = root.getElementById('empty');
            if (!grid) return;
            
            grid.innerHTML = '';
            const hasServices = Array.isArray(services) && services.length > 0;
            
            if (hasServices) {
                services.forEach(s => {
                    const el = (this._type === 'ssh') ? 
                        document.createElement('app-ssh-service-card') : 
                        document.createElement('app-http-service-card');
                    el.data = s;
                    grid.appendChild(el);
                });
                if (empty) empty.style.display = 'none';
            } else {
                if (empty) empty.style.display = '';
            }
        }
        render(){
            const root = this.shadowRoot;
            if (!root.firstChild) root.appendChild(this._rootTpl.content.cloneNode(true));
        }
    }

    // Footer component
    class AppFooter extends HTMLElement {
        constructor(){
            super();
            this.attachShadow({ mode: 'open' });
            this._rootTpl = createTemplate(`
                <style>
                    .footer { background: var(--clr-bg-highlight); border-top:1px solid var(--clr-border); padding: 1.25rem 0; }
                    .content { max-width: var(--container-2xl); margin: 0 auto; padding: 0 var(--spacing-xl); display:flex; align-items:center; justify-content:center; color: var(--clr-text-muted); font-size:0.9rem; }
                    .links { display:flex; gap:0.75rem; }
                    a { color: var(--clr-primary-base); text-decoration:none; }
                    a:hover { text-decoration:underline; }
                </style>
                <footer class="footer">
                    <div class="content">
                        <div class="copy"><a href="https://quantumblockchains.io" target="_blank" rel="noopener">© <span id="year"></span> Quantum Blockchains</a> | <span id="footer-title">QB Jump Server</span></div>
                        <div class="links"><slot name="links"></slot></div>
                    </div>
                </footer>
            `);
        }
        connectedCallback(){
            const root = this.shadowRoot;
            if (!root.firstChild) root.appendChild(this._rootTpl.content.cloneNode(true));
            const year = root.getElementById('year');
            if (year) year.textContent = String(new Date().getFullYear());
            
            // Update title from configuration and keep in sync with config-loaded
            const titleEl = root.getElementById('footer-title');
            const apply = (cfg)=>{ try { const title = (cfg && cfg.title) || (window.__APP_CONFIG__ && window.__APP_CONFIG__.title) || null; if (titleEl && title) titleEl.textContent = title; } catch(_){} };
            document.addEventListener('app:config-loaded', (e)=> apply(e && e.detail && e.detail.config));
            apply(window.__APP_CONFIG__);
        }
    }
    // Base card
    class AppServiceCard extends HTMLElement {
        static get observedAttributes() { return ['name','enabled','type']; }

        constructor() {
            super();
            this.attachShadow({ mode: 'open' });
            this._data = null;
            this._rootTpl = createTemplate(`
                <style>
                    :host { display: block; }
                    .card { 
                        border: 1px solid var(--clr-border-muted); 
                        border-radius: var(--radius-lg); 
                        padding: 0; 
                        background: var(--clr-bg-dark); 
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
                        border: 1px solid var(--clr-primary-base); 
                        background: var(--clr-primary-base); 
                        padding: 8px 16px; 
                        border-radius: var(--radius-md); 
                        cursor: pointer; 
                        font-size: 13px;
                        font-weight: 500;
                        color: var(--clr-highlight);
                        transition: all 0.15s ease;
                        display: inline-flex;
                        align-items: center;
                        gap: 6px;
                    }
                    .btn:hover { 
                        background: var(--clr-primary-light);
                        border-color: var(--clr-primary-light);
                        transform: translateY(-1px);
                    }
                    .btn:active {
                        transform: translateY(0);
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
                    .icon-external-link { -webkit-mask-image: url(/static/icons/external-link.svg); mask-image: url(/static/icons/external-link.svg); }
                </style>
                <div class="card">
                    <div class="card-content">
                        <div class="icon-wrapper">
                            <div class="icon"></div>
                        </div>
                        <div class="header">
                            <div class="name"></div>
                        </div>
                        <div class="meta"></div>
                    </div>
                    <div class="actions">
                        <button class="btn open">
                            <span class="btn-icon icon-external-link"></span>
                            <span>Open</span>
                        </button>
                    </div>
                </div>
            `);
        }

        set data(value) {
            this._data = value || null;
            this.render();
        }

        get data() { return this._data; }

        connectedCallback() { this.render(); this._wire(); }

        attributeChangedCallback() { this.render(); }

        render() {
            const root = this.shadowRoot;
            if (!root) return;
            if (!root.firstChild) {
                root.appendChild(this._rootTpl.content.cloneNode(true));
            }
            const nameEl = root.querySelector('.name');
            const metaEl = root.querySelector('.meta');
            const d = this._data || {};
            const name = this.getAttribute('name') || d.name || d.id || '';
            if (nameEl) nameEl.textContent = name;
            if (metaEl) {
                const description = d.description || '';
                const rows = [];
                if (description) rows.push(`<div class="row"><span class="value">${description}</span></div>`);
                metaEl.innerHTML = rows.join('');
            }
        }

        _wire() {
            if (this._isWired) return; // Prevent duplicate bindings
            this._isWired = true;
            
            const root = this.shadowRoot;
            if (!root) return;
            
            // Make entire card clickable
            const card = root.querySelector('.card');
            card && card.addEventListener('click', (e) => {
                // Don't trigger if clicking on the button itself (avoid double navigation)
                if (!e.target.closest('.btn')) {
                    this._open();
                }
            });
            
            const openBtn = root.querySelector('.btn.open');
            openBtn && openBtn.addEventListener('click', (e) => {
                e.stopPropagation(); // Prevent double trigger
                this._open();
            });
        }

        _open() {
            const d = this._data || {};
            const id = d && d.id;
            if (!id) return;
            const type = (this.getAttribute('type') || d.type || 'http').toLowerCase();
            const href = type === 'ssh' ? `/ssh/${id}` : `/http/${id}`;
            try { window.open(href, '_blank'); } catch (_) {}
        }
    }

    // HTTP card
    class AppHttpServiceCard extends AppServiceCard {
        render() {
            super.render();
            const root = this.shadowRoot;
            if (!root) return;
            
            const d = this._data || {};
            
            // Update icon in icon-wrapper
            const iconWrapper = root.querySelector('.icon');
            if (iconWrapper) {
                let faviconHtml = '';
                if (d.id) {
                    // Use backend favicon endpoint which handles extraction and caching
                    const faviconUrl = `/api/v1/services/http/${d.id}/favicon`;
                    faviconHtml = `<img src="${faviconUrl}" alt="" onerror="this.src='data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 100 100%22><text y=%22.9em%22 font-size=%2290%22>🌐</text></svg>';" style="width:24px;height:24px;">`;
                } else {
                    faviconHtml = `<span style="font-size: 20px;">🌐</span>`;
                }
                iconWrapper.innerHTML = faviconHtml;
            }
            
            // Update meta with just description
            const metaEl = root.querySelector('.meta');
            if (metaEl) {
                const description = d.description || '';
                const rows = [];
                if (description) rows.push(`<div class="row"><span class="value">${description}</span></div>`);
                metaEl.innerHTML = rows.join('');
            }
        }
    }

    // SSH card
    class AppSshServiceCard extends AppServiceCard {
        render() {
            super.render();
            const root = this.shadowRoot;
            if (!root) return;
            
            const d = this._data || {};
            
            // Update icon in icon-wrapper with SSH icon
            const iconWrapper = root.querySelector('.icon');
            if (iconWrapper) {
                // SSH icon SVG (terminal/console icon)
                const sshIconSvg = `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"></polyline><line x1="12" y1="19" x2="20" y2="19"></line></svg>`;
                iconWrapper.innerHTML = sshIconSvg;
            }
            
            // Update meta with description and endpoint
            const metaEl = root.querySelector('.meta');
            if (metaEl) {
                const description = d.description || '';
                const rows = [];
                if (description) rows.push(`<div class="row"><span class="value">${description}</span></div>`);
                
                // Add connection info
                if (d.host && d.port) {
                    rows.push(`<div class="row">
                        <span class="label">Endpoint:</span>
                        <span class="value">${d.host}:${d.port}</span>
                    </div>`);
                }
                
                metaEl.innerHTML = rows.join('');
            }
        }
    }


    if (!customElements.get('app-service-card')) customElements.define('app-service-card', AppServiceCard);
    if (!customElements.get('app-http-service-card')) customElements.define('app-http-service-card', AppHttpServiceCard);
    if (!customElements.get('app-ssh-service-card')) customElements.define('app-ssh-service-card', AppSshServiceCard);
    if (!customElements.get('app-header')) customElements.define('app-header', AppHeader);
    if (!customElements.get('app-dashboard-services')) customElements.define('app-dashboard-services', AppDashboardServices);
    if (!customElements.get('app-footer')) customElements.define('app-footer', AppFooter);
    if (!customElements.get('app-service-status-modal')) customElements.define('app-service-status-modal', AppServiceStatusModal);
    if (!customElements.get('app-diagnostics-modal')) customElements.define('app-diagnostics-modal', AppDiagnosticsModal);
})();


