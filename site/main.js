// Fade sections in as they scroll into view. The page works without it.
if ("IntersectionObserver" in window) {
  const io = new IntersectionObserver((entries) => {
    for (const e of entries) if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
  }, { threshold: 0.15 });
  document.querySelectorAll(".card, .split > *, .steps li, h2").forEach((el) => {
    el.classList.add("reveal");
    io.observe(el);
  });
}
