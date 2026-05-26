/**
 * SWTool Landing Page - Interactive Behaviors
 */
document.addEventListener('DOMContentLoaded', () => {
  // 1. Mobile Menu Toggle
  const navToggle = document.getElementById('nav-toggle');
  const navMenu = document.getElementById('nav-menu');

  if (navToggle && navMenu) {
    navToggle.addEventListener('click', (e) => {
      e.stopPropagation();
      navMenu.classList.toggle('open');
      navToggle.classList.toggle('active');
      
      // Accessibility attributes
      const expanded = navMenu.classList.contains('open');
      navToggle.setAttribute('aria-expanded', expanded);
    });

    // Close menu when clicking on a link
    const navLinks = navMenu.querySelectorAll('.nav-link');
    navLinks.forEach(link => {
      link.addEventListener('click', () => {
        navMenu.classList.remove('open');
        navToggle.classList.remove('active');
        navToggle.setAttribute('aria-expanded', 'false');
      });
    });

    // Close menu when clicking outside
    document.addEventListener('click', (e) => {
      if (!navMenu.contains(e.target) && !navToggle.contains(e.target)) {
        navMenu.classList.remove('open');
        navToggle.classList.remove('active');
        navToggle.setAttribute('aria-expanded', 'false');
      }
    });
  }

  // 2. Sticky Header & Shrink on Scroll
  const header = document.getElementById('header');
  if (header) {
    const handleScroll = () => {
      if (window.scrollY > 30) {
        header.classList.add('scrolled');
      } else {
        header.classList.remove('scrolled');
      }
    };
    window.addEventListener('scroll', handleScroll);
    handleScroll(); // Initial check on load
  }

  // 3. Active Nav Link Highlighting based on Scroll Position
  const sections = document.querySelectorAll('section[id], footer[id]');
  const navLinks = document.querySelectorAll('.nav-link');

  const highlightNav = () => {
    const scrollPos = window.scrollY + 150; // offset for sticky header

    sections.forEach(section => {
      const top = section.offsetTop;
      const height = section.offsetHeight;
      const id = section.getAttribute('id');

      if (scrollPos >= top && scrollPos < top + height) {
        navLinks.forEach(link => {
          link.classList.remove('active');
          if (link.getAttribute('href') === `#${id}`) {
            link.classList.add('active');
          }
        });
      }
    });
  };
  window.addEventListener('scroll', highlightNav);
  highlightNav(); // Initial check

  // 4. Smooth Scroll for Internal Links
  const allLinks = document.querySelectorAll('a[href^="#"]');
  allLinks.forEach(link => {
    link.addEventListener('click', function(e) {
      const href = this.getAttribute('href');
      if (href === '#') return;

      const targetEl = document.querySelector(href);
      if (targetEl) {
        e.preventDefault();
        const headerHeight = header ? header.offsetHeight : 80;
        const targetPosition = targetEl.getBoundingClientRect().top + window.scrollY - headerHeight + 10;
        
        window.scrollTo({
          top: targetPosition,
          behavior: 'smooth'
        });
      }
    });
  });

  // 5. Scroll Reveal (Fade in sections/cards as they enter view)
  const revealElements = document.querySelectorAll('.feature-card, .price-card, .step-item, .hero-content, .hero-mockup, .faq-item');
  
  if ('IntersectionObserver' in window) {
    const revealObserver = new IntersectionObserver((entries, observer) => {
      entries.forEach(entry => {
        if (entry.isIntersecting) {
          entry.target.classList.add('revealed');
          observer.unobserve(entry.target); // Stop observing once revealed
        }
      });
    }, {
      threshold: 0.1,
      rootMargin: '0px 0px -50px 0px'
    });

    revealElements.forEach(el => {
      el.classList.add('reveal-init');
      revealObserver.observe(el);
    });
  } else {
    // Fallback if IntersectionObserver is not supported
    revealElements.forEach(el => {
      el.classList.add('revealed');
    });
  }

  // 6. Lightbox Event Bindings
  const lightbox = document.getElementById('lightbox');
  const lightboxClose = document.getElementById('lightbox-close');

  if (lightbox && lightboxClose) {
    lightboxClose.addEventListener('click', window.closeLightbox);
    
    // Close on clicking backdrop
    lightbox.addEventListener('click', (e) => {
      if (e.target === lightbox) {
        window.closeLightbox();
      }
    });

    // Close on Escape key
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && lightbox.classList.contains('open')) {
        window.closeLightbox();
      }
    });
  }

  // 7. FAQ Accordion Toggle
  const faqItems = document.querySelectorAll('.faq-item');
  faqItems.forEach(item => {
    const question = item.querySelector('.faq-question');
    if (question) {
      question.addEventListener('click', () => {
        const isActive = item.classList.contains('active');
        // Close all items
        faqItems.forEach(i => i.classList.remove('active'));
        // Toggle current item
        if (!isActive) {
          item.classList.add('active');
        }
      });
    }
  });
});

// Global Lightbox Functions
window.openLightbox = function(src, title) {
  const lightbox = document.getElementById('lightbox');
  const lightboxImg = document.getElementById('lightbox-img');
  const lightboxCaption = document.getElementById('lightbox-caption');

  if (lightbox && lightboxImg && lightboxCaption) {
    lightboxImg.src = src;
    lightboxImg.alt = title;
    lightboxCaption.textContent = title;
    lightbox.classList.add('open');
    document.body.style.overflow = 'hidden'; // Disable page scrolling
  }
};

window.closeLightbox = function() {
  const lightbox = document.getElementById('lightbox');
  if (lightbox) {
    lightbox.classList.remove('open');
    document.body.style.overflow = ''; // Restore page scrolling
  }
};
