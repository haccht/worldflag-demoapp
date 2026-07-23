document.addEventListener('DOMContentLoaded', () => {
  const form  = document.getElementById('answer-form');
  if (!form) return;

  const btns  = document.querySelectorAll('.option-btn');
  const fb    = document.getElementById('feedback');
  const next  = document.getElementById('next-btn');
  const answerLink = document.getElementById('answer-link');

  btns.forEach(b => b.addEventListener('click', async e => {
    b.classList.remove('btn-outline-primary');
    b.classList.add('btn-primary');
    e.preventDefault();

    const fd = new FormData();
    fd.append('guess', b.value);

    const res  = await fetch('/quiz/answer', { method: 'POST', body: fd });
    const data = await res.json();

    fb.textContent = data.correct ? '✔ Correct!' : '✘ Wrong!';
    fb.className   = data.correct ? 'text-success fw-bold' : 'text-danger fw-bold';
    answerLink.classList.add('d-none');
    if (!data.correct && data.answer && data.answer.code) {
      answerLink.textContent = 'Show answer';
      answerLink.href = `/country/${data.answer.code}`;
      answerLink.classList.remove('d-none');
    }

    btns.forEach(x => x.disabled = true);
    next.classList.remove('d-none');
  }));
});
