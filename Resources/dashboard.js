(() => {
  'use strict';

  let snapshot = null;
  let activePeriod = 'tracked';
  const PRO_MONTHLY_PRICE = 200;
  const WEEKS_PER_MONTH = 365.2425 / 12 / 7;
  const $ = (id) => document.getElementById(id);
  const colors = ['#a468ff', '#d56dff', '#6fd9ff', '#ffbd6c', '#6ee5b7', '#ff769e'];

  const post = (action) => {
    const bridge = window.webkit?.messageHandlers?.codexPulse;
    if (bridge) bridge.postMessage({ action });
  };

  const num = (value) => Number(value || 0);

  function compact(value, digits = 2) {
    const amount = num(value);
    if (amount >= 1e9) return `${(amount / 1e9).toFixed(digits)}B`;
    if (amount >= 1e6) return `${(amount / 1e6).toFixed(digits)}M`;
    if (amount >= 1e3) return `${(amount / 1e3).toFixed(1)}K`;
    return Math.round(amount).toLocaleString();
  }

  function decimal(value, maximum = 1) {
    return num(value).toLocaleString(undefined, { maximumFractionDigits: maximum });
  }

  function money(value) {
    return num(value).toLocaleString(undefined, { style: 'currency', currency: 'USD', minimumFractionDigits: 2, maximumFractionDigits: 2 });
  }

  function parseDate(value) {
    const date = value ? new Date(value) : null;
    return date && !Number.isNaN(date.getTime()) ? date : null;
  }

  function relativeTime(value) {
    const date = parseDate(value);
    if (!date) return 'waiting for data';
    const seconds = Math.max(0, Math.round((Date.now() - date.getTime()) / 1000));
    if (seconds < 8) return 'updated just now';
    if (seconds < 60) return `updated ${seconds}s ago`;
    const minutes = Math.floor(seconds / 60);
    if (minutes < 60) return `updated ${minutes}m ago`;
    return `updated ${Math.floor(minutes / 60)}h ago`;
  }

  function countdown(unixSeconds) {
    const remaining = Math.max(0, num(unixSeconds) * 1000 - Date.now());
    if (!remaining) return 'Awaiting reset data';
    const hours = Math.floor(remaining / 3_600_000);
    const days = Math.floor(hours / 24);
    const mins = Math.floor((remaining % 3_600_000) / 60_000);
    return days > 0 ? `${days}d ${hours % 24}h` : `${hours}h ${mins}m`;
  }

  function setText(id, text) {
    const element = $(id);
    if (element) element.textContent = text;
  }

  function currentAggregate() {
    return snapshot?.periods?.[activePeriod] || {};
  }

  function renderHeadline() {
    const aggregate = currentAggregate();
    setText('total-tokens', compact(aggregate.total));
    setText('input-tokens', compact(aggregate.input));
    setText('cached-tokens', compact(aggregate.cached));
    setText('output-tokens', compact(aggregate.output));
    setText('token-sessions', decimal(aggregate.sessionCount, 0));
    setText('token-events', decimal(aggregate.eventCount, 0));

    setText('estimated-credits', decimal(aggregate.credits, 1));
    setText('api-cost', money(aggregate.apiCost));
    const coverage = Math.max(0, Math.min(100, num(aggregate.pricingCoverage)));
    setText('pricing-coverage', `${coverage.toFixed(1)}%`);
    $('coverage-bar').style.width = `${coverage}%`;
    setText('pricing-caption', coverage < 99.95 ? 'Known models only; unknown models stay in raw totals' : 'Current official token rates · estimate only');

    renderComposition(aggregate);
  }

  function renderLimit() {
    const limit = snapshot?.limit || {};
    const available = Object.keys(limit).length > 0;
    const used = Math.max(0, Math.min(100, num(limit.usedPercent)));
    const remaining = 100 - used;
    setText('limit-percent', available ? `${remaining.toFixed(0)}%` : '—');
    setText('limit-ring-number', available ? `${remaining.toFixed(0)}%` : '—');
    $('limit-ring').style.setProperty('--limit', remaining);
    setText('limit-plan', available ? `${String(limit.planType || 'Codex').toUpperCase()} · ${decimal(limit.windowMinutes / 1440, 0)} day window` : 'Waiting for a Codex usage event');
    setText('reset-countdown', available ? countdown(limit.resetsAt) : '—');
    const reset = num(limit.resetsAt) ? new Date(num(limit.resetsAt) * 1000) : null;
    setText('reset-date', reset ? reset.toLocaleString(undefined, { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : 'No reset timestamp yet');
  }

  function renderWeeklyPlanEstimate() {
    const weeklySession = snapshot?.periods?.weeklySession || {};
    const localTokens = num(weeklySession.total);
    const localCost = num(weeklySession.apiCost);
    const weeklyBudget = PRO_MONTHLY_PRICE / WEEKS_PER_MONTH;
    const allowance = localTokens > 0 && localCost > 0 ? weeklyBudget * localTokens / localCost : 0;
    const used = localCost > 0 ? 100 * localCost / weeklyBudget : 0;

    setText('weekly-token-allowance', allowance > 0 ? `~${compact(allowance)}` : '—');
    setText('weekly-local-tokens', compact(localTokens));
    setText('weekly-plan-used', localCost > 0 ? `${used.toFixed(1)}%` : '—');
    $('weekly-plan-bar').style.width = `${Math.min(100, used)}%`;
    setText('weekly-plan-note', localCost > 0
      ? `~${money(weeklyBudget)} weekly benchmark at current API-equivalent rates`
      : 'Waiting for locally priced usage');
  }

  function renderComposition(aggregate) {
    const input = num(aggregate.input);
    const output = num(aggregate.output);
    const total = Math.max(1, input + output);
    const cached = num(aggregate.cached);
    const reasoning = num(aggregate.reasoning);
    const rows = [
      { name: 'Input', value: input, percent: 100 * input / total, className: 'input' },
      { name: 'Cached input', value: cached, percent: input ? 100 * cached / input : 0, className: 'cached' },
      { name: 'Output', value: output, percent: 100 * output / total, className: 'output' },
      { name: 'Reasoning output', value: reasoning, percent: output ? 100 * reasoning / output : 0, className: 'reasoning' }
    ];
    $('composition-bars').innerHTML = rows.map((row) => `
      <div class="composition-row">
        <div class="composition-row-head"><span>${row.name}</span><strong>${compact(row.value)} · ${row.percent.toFixed(1)}%</strong></div>
        <div class="composition-track"><span class="${row.className}" style="width:${Math.min(100, row.percent)}%"></span></div>
      </div>`).join('');
    setText('cache-efficiency', input ? `${(100 * cached / input).toFixed(1)}% of input served from cache` : 'No input yet');
  }

  function renderTrend() {
    const daily = snapshot?.daily || [];
    const values = daily.map((day) => num(day.total));
    const max = Math.max(1, ...values);
    const width = 720;
    const height = 215;
    const top = 18;
    const bottom = 194;
    const points = values.map((value, index) => {
      const x = daily.length > 1 ? index * width / (daily.length - 1) : width / 2;
      const y = bottom - (value / max) * (bottom - top);
      return { x, y, value };
    });
    const linePath = points.map((point, index) => `${index ? 'L' : 'M'} ${point.x.toFixed(2)} ${point.y.toFixed(2)}`).join(' ');
    const areaPath = points.length ? `${linePath} L ${width} ${bottom} L 0 ${bottom} Z` : '';
    const grid = [0, 1, 2, 3].map((index) => {
      const y = top + index * (bottom - top) / 3;
      return `<line class="chart-grid" x1="0" x2="720" y1="${y}" y2="${y}"/>`;
    }).join('');
    const circles = points.map((point) => `<circle class="chart-point" cx="${point.x}" cy="${point.y}" r="4"><title>${compact(point.value)} tokens</title></circle>`).join('');
    $('trend-chart').innerHTML = `
      <defs>
        <linearGradient id="lineGradient" x1="0" x2="1"><stop stop-color="#7650ff"/><stop offset=".55" stop-color="#b366ff"/><stop offset="1" stop-color="#e16fff"/></linearGradient>
        <linearGradient id="areaGradient" x1="0" y1="0" x2="0" y2="1"><stop stop-color="#9c5dff" stop-opacity=".31"/><stop offset="1" stop-color="#9c5dff" stop-opacity="0"/></linearGradient>
      </defs>${grid}<path class="chart-area" d="${areaPath}"/><path class="chart-line" d="${linePath}"/>${circles}`;
    $('chart-labels').innerHTML = daily.map((day) => {
      const date = parseDate(`${day.date}T12:00:00`);
      return `<span>${date ? date.toLocaleDateString(undefined, { weekday: 'short' }) : '—'}</span>`;
    }).join('');
  }

  function renderModels() {
    const models = snapshot?.models || [];
    const max = Math.max(1, ...models.map((model) => num(model.total)));
    $('model-list').innerHTML = models.length ? models.map((model, index) => `
      <div class="model-row" style="--gem:${colors[index % colors.length]}">
        <div class="model-row-top">
          <div class="model-name"><i class="model-gem"></i>${escapeHTML(model.name)}</div>
          <div class="model-total">${compact(model.total)} · ${decimal(model.credits, 1)} cr</div>
        </div>
        <div class="model-track"><span style="width:${100 * num(model.total) / max}%"></span></div>
      </div>`).join('') : '<div class="empty-state">No model usage has been recorded yet.</div>';
  }

  function renderSessions() {
    const sessions = snapshot?.sessions || [];
    $('session-list').innerHTML = sessions.length ? sessions.map((session) => `
      <div class="session-row">
        <div class="session-main"><strong>${escapeHTML(session.project)}</strong><span>${escapeHTML(session.originator)}</span></div>
        <div class="session-model"><strong>${escapeHTML(session.model)}</strong><span>${escapeHTML(session.tierLabel)}</span></div>
        <div class="session-tokens">${compact(session.total)}</div>
      </div>`).join('') : '<div class="empty-state">Waiting for a local Codex session.</div>';
  }

  function escapeHTML(value) {
    return String(value ?? '').replace(/[&<>'"]/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' }[char]));
  }

  function renderMeta() {
    setText('last-updated', relativeTime(snapshot?.generatedAt));
    const trackingStart = parseDate(snapshot?.trackingStart);
    setText('tracking-start', trackingStart ? trackingStart.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' }) : '—');
    const health = snapshot?.health || {};
    setText('health-summary', `${decimal(health.filesTracked, 0)} files · ${decimal(health.eventsTracked, 0)} events · rates ${health.pricingPublished || 'unknown'}`);
    setText('pricing-published', health.pricingPublished || 'Unknown');
  }

  function render() {
    if (!snapshot) return;
    renderHeadline();
    renderLimit();
    renderWeeklyPlanEstimate();
    renderTrend();
    renderModels();
    renderSessions();
    renderMeta();
  }

  window.codexPulseUpdate = (nextSnapshot) => {
    snapshot = nextSnapshot || {};
    render();
  };

  $('period-control').addEventListener('click', (event) => {
    const button = event.target.closest('button[data-period]');
    if (!button) return;
    activePeriod = button.dataset.period;
    document.querySelectorAll('#period-control button').forEach((candidate) => candidate.classList.toggle('active', candidate === button));
    renderHeadline();
  });

  const drawer = $('settings-drawer');
  const setDrawer = (open) => {
    drawer.classList.toggle('open', open);
    drawer.setAttribute('aria-hidden', String(!open));
  };
  $('settings-button').addEventListener('click', () => setDrawer(true));
  $('close-settings').addEventListener('click', () => setDrawer(false));
  $('drawer-backdrop').addEventListener('click', () => setDrawer(false));
  $('refresh-button').addEventListener('click', () => post('refresh'));
  $('reset-data').addEventListener('click', () => post('reset'));
  $('reveal-data').addEventListener('click', () => post('revealData'));
  $('open-pricing').addEventListener('click', () => post('openPricing'));
  window.addEventListener('keydown', (event) => { if (event.key === 'Escape') setDrawer(false); });
  setInterval(() => { if (snapshot) setText('last-updated', relativeTime(snapshot.generatedAt)); }, 15_000);
})();
