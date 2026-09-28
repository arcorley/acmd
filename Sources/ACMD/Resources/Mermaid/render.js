(() => {
  const blocks = Array.from(document.querySelectorAll('.mermaid-diagram')).map(element => ({
    element,
    source: element.querySelector('.mermaid-source'),
    text: element.querySelector('.mermaid-source').textContent
  }));
  const appearance = window.matchMedia('(prefers-color-scheme: dark)');
  let rendering = Promise.resolve();
  let generation = 0;

  async function renderAll() {
    const dark = !window.__acmdMermaidForceLight && appearance.matches;
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: 'strict',
      suppressErrorRendering: true,
      theme: dark ? 'dark' : 'default',
      fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif',
      // Keep document directives from weakening sanitization or running code.
      secure: ['secure', 'securityLevel', 'startOnLoad', 'maxTextSize', 'maxEdges',
               'suppressErrorRendering', 'dompurifyConfig'],
      htmlLabels: false,
      arrowMarkerAbsolute: true
    });

    for (const [index, block] of blocks.entries()) {
      const staging = document.createElement('div');
      staging.style.cssText = 'position:absolute;left:-100000px;top:0;visibility:hidden;';
      staging.style.width = `${block.element.clientWidth}px`;
      document.body.append(staging);
      try {
        const { svg } = await mermaid.render(`acmd-mermaid-${generation}-${index}`, block.text, staging);
        const diagram = document.createElement('div');
        diagram.className = 'mermaid-rendered';
        diagram.innerHTML = svg;
        block.element.querySelector('.mermaid-rendered')?.remove();
        block.element.querySelector('.mermaid-error')?.remove();
        block.element.append(diagram);
        block.source.hidden = true;
        block.element.dataset.mermaidState = 'rendered';
      } catch (error) {
        block.element.querySelector('.mermaid-rendered')?.remove();
        block.element.querySelector('.mermaid-error')?.remove();
        const message = document.createElement('p');
        message.className = 'mermaid-error';
        message.setAttribute('role', 'status');
        message.textContent = `Unable to render Mermaid diagram: ${error.message || String(error)}`;
        block.element.prepend(message);
        block.source.hidden = false;
        block.element.dataset.mermaidState = 'error';
      } finally {
        staging.remove();
      }
    }
    generation += 1;
    // Notify the preview's existing scroll bridge after diagram layout changes.
    window.dispatchEvent(new Event('resize'));
  }

  function scheduleRender() {
    rendering = rendering.catch(() => {}).then(renderAll);
    window.__acmdMermaidReady = rendering;
  }

  if (!window.__acmdMermaidForceLight) {
    appearance.addEventListener('change', scheduleRender);
  }
  scheduleRender();
})();
