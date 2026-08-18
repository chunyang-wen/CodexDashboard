const revealItems = document.querySelectorAll('[data-reveal]');

if ('IntersectionObserver' in window) {
  const observer = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        entry.target.classList.add('revealed');
        observer.unobserve(entry.target);
      }
    });
  }, { threshold: 0.12 });

  revealItems.forEach((item) => observer.observe(item));
} else {
  revealItems.forEach((item) => item.classList.add('revealed'));
}

document.querySelectorAll('[data-copy]').forEach((button) => {
  const initialLabel = button.textContent;
  button.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(button.dataset.copy);
      button.textContent = 'COPIED ✓';
      window.setTimeout(() => { button.textContent = initialLabel; }, 1600);
    } catch {
      button.textContent = 'SELECT + COPY';
    }
  });
});

document.getElementById('year').textContent = new Date().getFullYear();
