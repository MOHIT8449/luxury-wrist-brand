// Luxury Wrist Brand public website behaviour (index.html, brands.html).

// Business WhatsApp number in international format without "+" or spaces,
// e.g. "919876543210". If left empty, WhatsApp lets the visitor pick the
// recipient.
const WHATSAPP_NUMBER = "919512297456";

document.documentElement.classList.remove("no-js");

function whatsappUrl(text) {
    const base = "https://wa.me/" + WHATSAPP_NUMBER;
    return text ? base + "?text=" + encodeURIComponent(text) : base;
}

// Header turns solid once the page scrolls past the hero top.
const header = document.querySelector(".site-header");
if (header && !header.classList.contains("always-solid")) {
    const onScroll = () => header.classList.toggle("solid", window.scrollY > 40);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
}

// Mobile menu.
const toggle = document.querySelector(".menu-toggle");
if (toggle) {
    const setOpen = (open) => {
        document.body.classList.toggle("menu-open", open);
        toggle.setAttribute("aria-expanded", String(open));
        document.body.style.overflow = open ? "hidden" : "";
    };
    toggle.addEventListener("click", () => setOpen(!document.body.classList.contains("menu-open")));
    document.querySelectorAll(".menu a").forEach((a) => a.addEventListener("click", () => setOpen(false)));
    document.addEventListener("keydown", (e) => { if (e.key === "Escape") setOpen(false); });
}

// Reveal-on-scroll.
const revealEls = document.querySelectorAll(".reveal");
if ("IntersectionObserver" in window) {
    const io = new IntersectionObserver((entries) => {
        entries.forEach((entry) => {
            if (entry.isIntersecting) {
                entry.target.classList.add("in");
                io.unobserve(entry.target);
            }
        });
    }, { threshold: 0.12, rootMargin: "0px 0px -40px 0px" });
    revealEls.forEach((el) => io.observe(el));
} else {
    revealEls.forEach((el) => el.classList.add("in"));
}

// Plain WhatsApp links.
document.querySelectorAll("[data-whatsapp]").forEach((a) => {
    a.href = whatsappUrl(a.dataset.whatsapp);
    a.target = "_blank";
    a.rel = "noopener";
});

// Enquiry form: composes a WhatsApp message (the site has no backend).
const form = document.querySelector("#enquiry-form");
if (form) {
    form.addEventListener("submit", (e) => {
        e.preventDefault();
        if (!form.reportValidity()) return;
        const data = new FormData(form);
        const lines = [
            "Business enquiry from luxurywristbrand.com",
            "Name: " + data.get("name"),
            "Business: " + data.get("business"),
            "City: " + data.get("city"),
            "Interest: " + data.get("interest"),
        ];
        const message = String(data.get("message") || "").trim();
        if (message) lines.push("Message: " + message);
        window.open(whatsappUrl(lines.join("\n")), "_blank", "noopener");
    });
}

// Pre-select the enquiry interest from a brand page link (?interest=...).
const interest = new URLSearchParams(location.search).get("interest");
if (form && interest) {
    const select = form.querySelector("select[name=interest]");
    if ([...select.options].some((o) => o.value === interest)) select.value = interest;
}

// Brand portfolio category filter.
const chips = document.querySelectorAll(".chip[data-filter]");
if (chips.length) {
    const groups = document.querySelectorAll(".portfolio-category");
    const apply = (filter) => {
        chips.forEach((c) => c.setAttribute("aria-pressed", String(c.dataset.filter === filter)));
        groups.forEach((g) => { g.hidden = filter !== "all" && g.id !== filter; });
    };
    chips.forEach((chip) => chip.addEventListener("click", () => {
        apply(chip.dataset.filter);
        history.replaceState(null, "", chip.dataset.filter === "all" ? location.pathname : "#" + chip.dataset.filter);
    }));
    const fromHash = () => {
        const id = location.hash.slice(1);
        if (id && document.getElementById(id)?.classList.contains("portfolio-category")) apply(id);
    };
    fromHash();
    window.addEventListener("hashchange", fromHash);
}
