(() => {
  'use strict';

  let snapshot = null;
  let activePeriod = 'tracked';
  let chartPoints = [];
  const DIAL_CIRCUMFERENCE = 2 * Math.PI * 18.5;
  // Must match the viewBox on #trend-chart, which is drawn with
  // preserveAspectRatio="none" so both axes scale independently to the element box.
  const CHART_WIDTH = 720;
  const CHART_HEIGHT = 210;
  const CHART_TOP = 14;
  const CHART_BOTTOM = 196;
  const $ = (id) => document.getElementById(id);
  const swatches = ['#3b5ce0', '#7c5cf0', '#109a92', '#b57314', '#d94a68', '#2f7fb5'];

  const post = (action) => {
    const bridge = window.webkit?.messageHandlers?.codexPulse;
    if (bridge) bridge.postMessage({ action });
  };

  // Called by AppDelegate once the page loads, so the drawer's version label comes
  // from CFBundleShortVersionString rather than a string hand-edited at release time.
  window.codexPulseSetVersion = (version) => {
    setText('app-version', version ? `Codex Pulse ${version}` : 'Codex Pulse');
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
    if (seconds < 8) return 'just now';
    if (seconds < 60) return `${seconds}s ago`;
    const minutes = Math.floor(seconds / 60);
    if (minutes < 60) return `${minutes}m ago`;
    return `${Math.floor(minutes / 60)}h ago`;
  }

  function countdown(unixSeconds) {
    const remaining = Math.max(0, num(unixSeconds) * 1000 - Date.now());
    if (!remaining) return '—';
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
    setText('pricing-caption', coverage < 99.95
      ? 'Known models only; unknown models stay in raw totals'
      : 'Current official token rates · estimate only');

    renderRail(aggregate);
  }

  // Ratios the raw totals imply but never state outright. All are scoped to the
  // selected period so the rail moves with the segmented control.
  function renderRail(aggregate) {
    const total = num(aggregate.total);
    const input = num(aggregate.input);
    const output = num(aggregate.output);
    const events = num(aggregate.eventCount);
    const sessions = num(aggregate.sessionCount);
    const cost = num(aggregate.apiCost);

    setText('rail-per-call', events ? compact(total / events) : '—');
    setText('rail-calls-session', sessions ? decimal(events / sessions, 1) : '—');
    setText('rail-cache', input ? `${(100 * num(aggregate.cached) / input).toFixed(1)}%` : '—');
    setText('rail-reasoning', output ? `${(100 * num(aggregate.reasoning) / output).toFixed(1)}%` : '—');
    setText('rail-output', total ? `${(100 * output / total).toFixed(1)}%` : '—');
    setText('rail-rate', total && cost ? money(cost / total * 1e6) : '—');
  }

  function renderLimit() {
    const limit = snapshot?.limit || {};
    const available = Object.keys(limit).length > 0;
    const used = Math.max(0, Math.min(100, num(limit.usedPercent)));
    const remaining = 100 - used;

    setText('limit-percent', available ? `${remaining.toFixed(0)}%` : '—');
    $('limit-ring-arc').style.strokeDashoffset = String(DIAL_CIRCUMFERENCE * (1 - (available ? remaining : 0) / 100));

    const dial = $('limit-ring');
    dial.classList.toggle('warn', available && remaining <= 35 && remaining > 15);
    dial.classList.toggle('low', available && remaining <= 15);

    setText('limit-plan', available
      ? `${String(limit.planType || 'Codex').toUpperCase()} plan · ${decimal(limit.windowMinutes / 1440, 0)}-day window`
      : 'Waiting for a Codex usage event');
    setText('reset-countdown', available ? countdown(limit.resetsAt) : '—');
    const reset = num(limit.resetsAt) ? new Date(num(limit.resetsAt) * 1000) : null;
    setText('reset-date', reset
      ? reset.toLocaleString(undefined, { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })
      : 'No reset timestamp yet');
  }

  // Compares how much of the weekly limit is gone against how much of the window
  // has elapsed, then extrapolates the current rate out to the reset. The
  // projection is deliberately withheld early in a window, where dividing by a
  // tiny elapsed fraction produces a meaningless number.
  function renderPace() {
    const limit = snapshot?.limit || {};
    const windowSeconds = num(limit.windowMinutes) * 60;
    const used = Math.max(0, Math.min(100, num(limit.usedPercent)));
    const remainingSeconds = Math.max(0, num(limit.resetsAt) - Date.now() / 1000);
    const elapsed = windowSeconds > 0
      ? Math.max(0, Math.min(1, (windowSeconds - remainingSeconds) / windowSeconds))
      : 0;
    const canProject = windowSeconds > 0 && elapsed >= 0.08;
    const projected = canProject ? used / elapsed : 0;

    const pace = document.querySelector('.pace');
    const verdict = $('pace-verdict');
    pace.classList.toggle('over', canProject && projected > 100);

    $('pace-used-bar').style.width = `${used}%`;
    $('pace-projected-bar').style.width = `${canProject ? Math.max(0, Math.min(100 - used, projected - used)) : 0}%`;

    setText('pace-used', windowSeconds > 0 ? `${used.toFixed(1)}%` : '—');
    setText('pace-projected', canProject ? `${Math.min(999, projected).toFixed(0)}%` : '—');

    const elapsedDays = elapsed * windowSeconds / 86400;
    const weeklyTokens = num(snapshot?.periods?.weeklySession?.total);
    setText('pace-burn', elapsedDays >= 0.25 && weeklyTokens > 0
      ? `${compact(weeklyTokens / elapsedDays)} / day`
      : '—');

    if (windowSeconds <= 0) {
      verdict.textContent = 'No data';
      verdict.className = 'chip chip-mute';
      setText('pace-note', 'Waiting for a Codex usage event');
      return;
    }
    if (!canProject) {
      verdict.textContent = 'Early';
      verdict.className = 'chip chip-mute';
      setText('pace-note', `Only ${(100 * elapsed).toFixed(0)}% of the window has elapsed — too early to project a rate.`);
      return;
    }
    if (projected > 100) {
      verdict.textContent = 'Over pace';
      verdict.className = 'chip chip-bad';
      // Scaling the current rate by 100/projected lands exactly on the limit.
      setText('pace-note', `At this rate the limit runs out before the window resets. About ${(100 / projected * 100).toFixed(0)}% of your current rate would land on 100%.`);
      return;
    }
    if (projected > 85) {
      verdict.textContent = 'Running close';
      verdict.className = 'chip chip-warn';
      setText('pace-note', 'On track to finish the window near the limit, with little headroom left over.');
      return;
    }
    verdict.textContent = 'Comfortable';
    verdict.className = 'chip chip-good';
    setText('pace-note', `Tracking to use about ${projected.toFixed(0)}% of the weekly limit by reset.`);
  }

  function renderOrigins() {
    const origins = snapshot?.origins || [];
    const sum = origins.reduce((carry, origin) => carry + num(origin.total), 0);
    if (!origins.length || !sum) {
      $('origin-bar').innerHTML = '';
      $('origin-list').innerHTML = '<div class="empty-state">No session origins recorded yet.</div>';
      return;
    }
    $('origin-bar').innerHTML = origins.map((origin, index) =>
      `<span style="--swatch:${swatches[index % swatches.length]};width:${100 * num(origin.total) / sum}%"></span>`).join('');
    $('origin-list').innerHTML = origins.map((origin, index) => `
      <div class="origin-row" style="--swatch:${swatches[index % swatches.length]}">
        <div class="origin-name"><i class="model-swatch"></i><b>${escapeHTML(origin.name)}</b></div>
        <div class="origin-total">${compact(origin.total)}</div>
        <div class="origin-share">${(100 * num(origin.total) / sum).toFixed(1)}%</div>
      </div>`).join('');
  }

  function renderTrend() {
    const daily = snapshot?.daily || [];
    const values = daily.map((day) => num(day.total));
    const max = Math.max(1, ...values);
    const span = CHART_BOTTOM - CHART_TOP;

    chartPoints = values.map((value, index) => {
      const x = daily.length > 1 ? index * CHART_WIDTH / (daily.length - 1) : CHART_WIDTH / 2;
      return { x, y: CHART_BOTTOM - (value / max) * span, value, date: daily[index]?.date };
    });

    const linePath = chartPoints.map((point, index) => `${index ? 'L' : 'M'} ${point.x.toFixed(2)} ${point.y.toFixed(2)}`).join(' ');
    const areaPath = chartPoints.length ? `${linePath} L ${CHART_WIDTH} ${CHART_BOTTOM} L 0 ${CHART_BOTTOM} Z` : '';
    const grid = [0, 1, 2, 3].map((index) => {
      const y = CHART_TOP + index * span / 3;
      return `<line class="chart-grid" x1="0" x2="${CHART_WIDTH}" y1="${y}" y2="${y}"/>`;
    }).join('');
    $('trend-chart').innerHTML = `
      <defs>
        <linearGradient id="cpLine" x1="0" x2="1">
          <stop stop-color="var(--accent)"/>
          <stop offset="1" stop-color="var(--violet)"/>
        </linearGradient>
        <linearGradient id="cpArea" x1="0" y1="0" x2="0" y2="1">
          <stop stop-color="var(--accent)" stop-opacity=".26"/>
          <stop offset="1" stop-color="var(--accent)" stop-opacity="0"/>
        </linearGradient>
      </defs>
      ${grid}
      <path class="chart-area" d="${areaPath}"/>
      <path class="chart-line" d="${linePath}"/>
      <line class="chart-guide" id="chart-guide" y1="${CHART_TOP}" y2="${CHART_BOTTOM}" x1="0" x2="0"/>`;

    const firstDate = parseDate(`${daily[0]?.date || ''}T12:00:00`);
    const lastDate = parseDate(`${daily[daily.length - 1]?.date || ''}T12:00:00`);
    const formatRangeDate = (date) => date
      ? date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
      : '—';
    setText('trend-subtitle', daily.length
      ? `Daily tokens from ${formatRangeDate(firstDate)} through ${formatRangeDate(lastDate)}`
      : 'Daily tokens since local tracking began');
    $('trend-chart').setAttribute('aria-label', daily.length
      ? `Daily token usage from ${formatRangeDate(firstDate)} through ${formatRangeDate(lastDate)}`
      : 'Daily token usage');

    const todayKey = new Date().toISOString().slice(0, 10);
    const labelEvery = Math.max(1, Math.ceil(Math.max(1, daily.length - 1) / 6));
    $('chart-labels').style.gridTemplateColumns = `repeat(${Math.max(1, daily.length)}, minmax(0, 1fr))`;
    $('chart-labels').innerHTML = daily.map((day, index) => {
      const date = parseDate(`${day.date}T12:00:00`);
      const showLabel = index === 0 || index === daily.length - 1 || index % labelEvery === 0;
      const label = showLabel && date ? date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' }) : '';
      return `<span class="${day.date === todayKey ? 'today' : ''}">${escapeHTML(label)}</span>`;
    }).join('');
  }

  function bindChartHover() {
    const chart = $('chart');
    const svg = $('trend-chart');
    const tip = $('chart-tip');
    const cursor = $('chart-cursor');

    chart.addEventListener('mousemove', (event) => {
      if (!chartPoints.length) return;
      const bounds = svg.getBoundingClientRect();
      if (!bounds.width || !bounds.height) return;
      const ratio = (event.clientX - bounds.left) / bounds.width;
      const nearest = chartPoints.reduce((best, point, index) => {
        const distance = Math.abs(point.x / CHART_WIDTH - ratio);
        return distance < best.distance ? { distance, point, index } : best;
      }, { distance: Infinity, point: chartPoints[0], index: 0 });

      const guide = $('chart-guide');
      if (guide) {
        guide.setAttribute('x1', String(nearest.point.x));
        guide.setAttribute('x2', String(nearest.point.x));
      }
      const chartBounds = chart.getBoundingClientRect();
      const pointLeft = bounds.left - chartBounds.left + (nearest.point.x / CHART_WIDTH) * bounds.width;
      const pointTop = bounds.top - chartBounds.top + (nearest.point.y / CHART_HEIGHT) * bounds.height;
      cursor.style.left = `${pointLeft}px`;
      cursor.style.top = `${pointTop}px`;
      tip.style.left = `${pointLeft}px`;
      tip.style.top = `${pointTop}px`;
      tip.classList.toggle('below', nearest.point.y < CHART_TOP + 56);
      const date = parseDate(`${nearest.point.date}T12:00:00`);
      setText('chart-tip-day', date ? date.toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' }) : '—');
      setText('chart-tip-value', `${compact(nearest.point.value)} tokens`);
      // Deferring activation by a frame on first show lets the tip spring open in
      // place: the left/top transition only exists while .active, so applying both
      // in one recalc would animate it in from the panel's left edge.
      if (!chart.classList.contains('active')) {
        requestAnimationFrame(() => chart.classList.add('active'));
      }
    });

    chart.addEventListener('mouseleave', () => chart.classList.remove('active'));
  }

  function renderModels() {
    const models = snapshot?.models || [];
    const max = Math.max(1, ...models.map((model) => num(model.total)));
    const sum = models.reduce((carry, model) => carry + num(model.total), 0);
    $('model-list').innerHTML = models.length ? models.map((model, index) => `
      <div class="model-row" style="--swatch:${swatches[index % swatches.length]}">
        <div class="model-top">
          <div class="model-name"><i class="model-swatch"></i><b>${escapeHTML(model.name)}</b></div>
          <div class="model-share">${sum ? (100 * num(model.total) / sum).toFixed(1) : '0.0'}%</div>
        </div>
        <div class="model-meta">
          <span>${compact(model.total)} tokens</span>
          <span>${decimal(model.credits, 1)} credits</span>
        </div>
        <div class="model-track"><span style="width:${100 * num(model.total) / max}%"></span></div>
      </div>`).join('') : '<div class="empty-state">No model usage has been recorded yet.</div>';
  }

  function renderSessions() {
    const sessions = snapshot?.sessions || [];
    $('session-list').innerHTML = sessions.length ? sessions.map((session) => `
      <div class="session-row">
        <div class="session-cell"><strong>${escapeHTML(session.project)}</strong><small>${escapeHTML(session.originator)}</small></div>
        <div class="session-cell"><strong>${escapeHTML(session.model)}</strong><small>${escapeHTML(session.tierLabel)}</small></div>
        <div class="session-total">${compact(session.total)}</div>
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
    renderPace();
    renderTrend();
    renderModels();
    renderOrigins();
    renderSessions();
    renderMeta();
  }

  window.codexPulseUpdate = (nextSnapshot) => {
    snapshot = nextSnapshot || {};
    render();
  };

  // Parks the sliding thumb over the active segment. Driven from layout rather
  // than hard-coded widths, since the labels size themselves.
  function positionThumb() {
    const control = $('period-control');
    const thumb = $('period-thumb');
    const active = control.querySelector('button.active');
    if (!thumb || !active) return;
    thumb.style.setProperty('--thumb-x', `${active.offsetLeft}px`);
    thumb.style.setProperty('--thumb-w', `${active.offsetWidth}px`);
  }

  $('period-control').addEventListener('click', (event) => {
    const button = event.target.closest('button[data-period]');
    if (!button) return;
    activePeriod = button.dataset.period;
    document.querySelectorAll('#period-control button').forEach((candidate) => {
      const active = candidate === button;
      candidate.classList.toggle('active', active);
      candidate.setAttribute('aria-selected', String(active));
    });
    positionThumb();
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
  const refreshButton = $('refresh-button');
  refreshButton.addEventListener('click', () => {
    refreshButton.classList.remove('spinning');
    // Reading offsetWidth restarts the animation when clicked repeatedly.
    void refreshButton.offsetWidth;
    refreshButton.classList.add('spinning');
    post('refresh');
  });
  refreshButton.addEventListener('animationend', () => refreshButton.classList.remove('spinning'));
  $('reset-data').addEventListener('click', () => post('reset'));
  $('reveal-data').addEventListener('click', () => post('revealData'));
  $('open-pricing').addEventListener('click', () => post('openPricing'));
  window.addEventListener('keydown', (event) => { if (event.key === 'Escape') setDrawer(false); });
  // Feeds the pointer position to each pane's specular bloom. CSS handles showing
  // and hiding it on :hover, so this only ever writes two custom properties, and
  // coalesces to one write per frame.
  function bindSpecular() {
    let pending = null;
    let scheduled = false;
    document.addEventListener('pointermove', (event) => {
      const card = event.target.closest?.('.card');
      if (!card) return;
      pending = { card, x: event.clientX, y: event.clientY };
      if (scheduled) return;
      scheduled = true;
      requestAnimationFrame(() => {
        scheduled = false;
        const bounds = pending.card.getBoundingClientRect();
        pending.card.style.setProperty('--mx', `${pending.x - bounds.left}px`);
        pending.card.style.setProperty('--my', `${pending.y - bounds.top}px`);
      });
    }, { passive: true });
  }

  bindSpecular();
  bindChartHover();
  positionThumb();
  window.addEventListener('resize', positionThumb);
  setInterval(() => { if (snapshot) setText('last-updated', relativeTime(snapshot.generatedAt)); }, 15_000);
})();
