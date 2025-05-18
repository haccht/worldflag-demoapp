document.addEventListener('DOMContentLoaded', () => {
  console.log('loaded');
  const input  = document.getElementById('filter-input');
  const cards  = document.querySelectorAll('.country-card');

  input.addEventListener('input', () => {
    const q = input.value.trim().toLowerCase();

    cards.forEach(card => {
      const hit =
        card.dataset.name.includes(q) ||
        card.dataset.code.includes(q);
      card.classList.toggle('d-none', !hit);
    });
  });
});

