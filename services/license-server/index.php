<?php
// SWTool Russian Landing Page - Main Entry Point
?>
<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  
  <title>SWTool — Профессиональный плагин для SolidWorks | Автоматизация проектирования</title>
  
  <meta name="keywords" content="SWTool, плагин SolidWorks, SolidWorks автоматизация, надстройка SolidWorks, пакетная печать SolidWorks, спецификация BOM SolidWorks, переименование компонентов SolidWorks">
  <meta name="description" content="Ускорьте проектирование в SolidWorks в 10 раз с помощью SWTool. Пакетная печать чертежей, умный файловый менеджер, генерация BOM-отчетов, переименование компонентов с сохранением связей и пакетная конвертация файлов.">
  
  <!-- OpenGraph Metadata -->
  <meta property="og:title" content="SWTool — Профессиональный плагин для SolidWorks">
  <meta property="og:description" content="Ускорьте проектирование в SolidWorks в 10 раз с помощью SWTool. Пакетная печать чертежей, умный файловый менеджер, генерация BOM-отчетов.">
  <meta property="og:image" content="assets/img/ztool.png">
  <meta property="og:type" content="website">
  <meta property="og:url" content="http://z-tool.ru">
  
  <!-- Favicon -->
  <link href="assets/logo.svg" rel="icon" type="image/svg+xml">
  
  <!-- CSS -->
  <link href="css/landing.css" rel="stylesheet">
  
  <!-- Structured Data (JSON-LD) for SEO -->
  <script type="application/ld+json">
  {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    "name": "SWTool",
    "operatingSystem": "Windows 7, Windows 10, Windows 11",
    "applicationCategory": "DesignApplication, BusinessApplication",
    "offers": {
      "@type": "Offer",
      "price": "3200",
      "priceCurrency": "RUB"
    },
    "description": "Профессиональный плагин для SolidWorks. Автоматизация пакетной печати чертежей, умное управление файлами, генерация BOM-спецификаций, переименование компонентов с сохранением ссылочной целостности."
  }
  </script>
</head>
<body>

  <!-- Header -->
  <header class="header" id="header">
    <div class="container header-container">
      <a href="#" class="logo-link">
        <img src="assets/logo.svg" alt="SWTool Logo" width="130" height="35">
      </a>
      
      <nav class="nav" id="nav-menu">
        <a href="#features" class="nav-link">Возможности</a>
        <a href="#integration" class="nav-link">Как это работает</a>
        <a href="#faq" class="nav-link">Вопросы</a>
        <a href="#pricing" class="nav-link">Тарифы</a>
        <a href="#download" class="nav-link">Скачать</a>
      </nav>
      
      <div class="header-actions">
        <a href="#pricing" class="btn btn-primary" id="btn-header-buy">Купить лицензию</a>
      </div>
      
      <button class="hamburger" id="nav-toggle" aria-label="Открыть меню">
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
          <line x1="3" y1="12" x2="21" y2="12"></line>
          <line x1="3" y1="6" x2="21" y2="6"></line>
          <line x1="3" y1="18" x2="21" y2="18"></line>
        </svg>
      </button>
    </div>
  </header>

  <!-- Main Content -->
  <main>
    
    <!-- Hero Section -->
    <section class="hero" id="hero">
      <div class="container hero-grid">
        <div class="hero-content">
          <h1 class="hero-title"><span class="gradient-text">Ускорьте</span> проектирование в SolidWorks в 10 раз</h1>
          <p class="hero-desc">Профессиональный плагин, созданный инженерами для инженеров. Избавьтесь от рутинных операций: автоматизируйте переименование компонентов, создание спецификаций, печать чертежей и конвертацию форматов.</p>
          <div class="hero-actions">
            <a href="#download" class="btn btn-primary" id="btn-hero-download">Попробовать бесплатно</a>
            <a href="#features" class="btn btn-secondary" id="btn-hero-features">Возможности плагина</a>
          </div>
        </div>
        <div class="hero-mockup">
          <div class="glow-orb glow-orb-1"></div>
          <div class="glow-orb glow-orb-2"></div>
          <div class="hero-mockup-wrapper">
            <img src="assets/img/ztool.png" alt="Панель SWTool в SolidWorks" class="hero-screenshot" style="width:100%; height:auto; cursor:zoom-in;" onclick="openLightbox('assets/img/ztool.png', 'Панель SWTool в SolidWorks')">
          </div>
        </div>
      </div>
    </section>

    <!-- Features Section -->
    <section class="section" id="features">
      <div class="container">
        <h2 class="section-title">Все необходимые инструменты в одном плагине</h2>
        <p class="section-subtitle">SWTool содержит мощный набор функций для инженеров-конструкторов, автоматизирующих работу с файлами, чертежами и спецификациями.</p>
        
        <div class="features-grid">
          
          <!-- Feature 1 -->
          <div class="feature-card" id="feat-file-mgmt">
            <div class="feature-image-container" onclick="openLightbox('assets/img/ztool_1.png', 'Файловый менеджер')">
              <img src="assets/img/ztool_1.png" alt="Файловый менеджер SWTool" class="feature-image" loading="lazy">
              <div class="feature-image-overlay">
                <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="zoom-icon"><circle cx="11" cy="11" r="8"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line><line x1="11" y1="8" x2="11" y2="14"></line><line x1="8" y1="11" x2="14" y2="11"></line></svg>
              </div>
            </div>
            <div class="feature-card-content">
              <div class="feature-icon-wrapper">
                <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                  <path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"></path>
                  <circle cx="12" cy="14" r="2"></circle>
                  <path d="M12 10v2M12 16v2M8 14h2M14 14h2"></path>
                </svg>
              </div>
              <h3>Файловый менеджер</h3>
              <p>Пакетное переименование, разделение и слияние файлов, массовое редактирование свойств, материалов, единиц измерения и путей к внешним компонентам.</p>
            </div>
          </div>
          
          <!-- Feature 2 -->
          <div class="feature-card" id="feat-conversion">
            <div class="feature-image-container" onclick="openLightbox('assets/img/ztool_2.png', 'Конвертация форматов')">
              <img src="assets/img/ztool_2.png" alt="Конвертация форматов SWTool" class="feature-image" loading="lazy">
              <div class="feature-image-overlay">
                <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="zoom-icon"><circle cx="11" cy="11" r="8"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line><line x1="11" y1="8" x2="11" y2="14"></line><line x1="8" y1="11" x2="14" y2="11"></line></svg>
              </div>
            </div>
            <div class="feature-card-content">
              <div class="feature-icon-wrapper">
                <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                  <polyline points="17 1 21 5 17 9"></polyline>
                  <path d="M3 11V9a4 4 0 0 1 4-4h14M7 23 3 19 7 15"></path>
                  <path d="M21 13v2a4 4 0 0 1-4 4H3"></path>
                </svg>
              </div>
              <h3>Конвертация форматов</h3>
              <p>Массовое преобразование документов в PDF, DWG, DXF, STEP, IGS, XT, XB, STL, SAT, а также графические форматы PNG и JPG.</p>
            </div>
          </div>
          
          <!-- Feature 3 -->
          <div class="feature-card" id="feat-printing">
            <div class="feature-image-container" onclick="openLightbox('assets/img/ztool_3.png', 'Пакетная печать')">
              <img src="assets/img/ztool_3.png" alt="Пакетная печать SWTool" class="feature-image" loading="lazy">
              <div class="feature-image-overlay">
                <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="zoom-icon"><circle cx="11" cy="11" r="8"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line><line x1="11" y1="8" x2="11" y2="14"></line><line x1="8" y1="11" x2="14" y2="11"></line></svg>
              </div>
            </div>
            <div class="feature-card-content">
              <div class="feature-icon-wrapper">
                <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                  <polyline points="6 9 6 2 18 2 18 9"></polyline>
                  <path d="M6 18H4a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2h-2"></path>
                  <rect x="6" y="14" width="12" height="8"></rect>
                </svg>
              </div>
              <h3>Пакетная печать</h3>
              <p>Автоматическое распознавание размера чертежного формата (А0-А4), автоповорот ориентации листа и печать на соответствующих принтерах.</p>
            </div>
          </div>
          
          <!-- Feature 4 -->
          <div class="feature-card" id="feat-frames">
            <div class="feature-image-container" onclick="openLightbox('assets/img/ztool_4.png', 'Смена чертежных рамок')">
              <img src="assets/img/ztool_4.png" alt="Смена чертежных рамок SWTool" class="feature-image" loading="lazy">
              <div class="feature-image-overlay">
                <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="zoom-icon"><circle cx="11" cy="11" r="8"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line><line x1="11" y1="8" x2="11" y2="14"></line><line x1="8" y1="11" x2="14" y2="11"></line></svg>
              </div>
            </div>
            <div class="feature-card-content">
              <div class="feature-icon-wrapper">
                <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                  <rect x="3" y="3" width="18" height="18" rx="2" ry="2"></rect>
                  <line x1="9" y1="3" x2="9" y2="21"></line>
                  <line x1="3" y1="9" x2="21" y2="9"></line>
                </svg>
              </div>
              <h3>Смена чертежных рамок</h3>
              <p>Пакетная замена форматок листов, изменение стандарта оформления чертежей, скрытие или удаление подвешенных аннотаций.</p>
            </div>
          </div>
          
          <!-- Feature 5 -->
          <div class="feature-card" id="feat-references">
            <div class="feature-image-container" onclick="openLightbox('assets/img/ztool_5.png', 'Замена связей')">
              <img src="assets/img/ztool_5.png" alt="Замена связей SWTool" class="feature-image" loading="lazy">
              <div class="feature-image-overlay">
                <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="zoom-icon"><circle cx="11" cy="11" r="8"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line><line x1="11" y1="8" x2="11" y2="14"></line><line x1="8" y1="11" x2="14" y2="11"></line></svg>
              </div>
            </div>
            <div class="feature-card-content">
              <div class="feature-icon-wrapper">
                <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                  <path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"></path>
                  <path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"></path>
                </svg>
              </div>
              <h3>Замена связей</h3>
              <p>Массовое обновление и подмена ссылок на сопряженные детали и узлы внутри сборок SolidWorks без потери сопряжений.</p>
            </div>
          </div>
          
          <!-- Feature 6 -->
          <div class="feature-card" id="feat-drawing-sync">
            <div class="feature-image-container" onclick="openLightbox('assets/img/ztool_6.png', 'Синхронизация имен')">
              <img src="assets/img/ztool_6.png" alt="Синхронизация имен SWTool" class="feature-image" loading="lazy">
              <div class="feature-image-overlay">
                <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="zoom-icon"><circle cx="11" cy="11" r="8"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line><line x1="11" y1="8" x2="11" y2="14"></line><line x1="8" y1="11" x2="14" y2="11"></line></svg>
              </div>
            </div>
            <div class="feature-card-content">
              <div class="feature-icon-wrapper">
                <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                  <path d="M21.5 2v6h-6M21.34 15.57a10 10 0 1 1-.57-8.38l5.67-5.67"></path>
                </svg>
              </div>
              <h3>Синхронизация имен</h3>
              <p>Пакетное переименование файлов чертежей (`.SLDDRW`) в соответствии с именами связанных 3D-моделей деталей или сборок.</p>
            </div>
          </div>
          
          <!-- Feature 7 -->
          <div class="feature-card" id="feat-renaming">
            <div class="feature-image-container" onclick="openLightbox('assets/img/ztool_7.png', 'Умное переименование')">
              <img src="assets/img/ztool_7.png" alt="Умное переименование SWTool" class="feature-image" loading="lazy">
              <div class="feature-image-overlay">
                <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="zoom-icon"><circle cx="11" cy="11" r="8"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line><line x1="11" y1="8" x2="11" y2="14"></line><line x1="8" y1="11" x2="14" y2="11"></line></svg>
              </div>
            </div>
            <div class="feature-card-content">
              <div class="feature-icon-wrapper">
                <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                  <path d="M20.59 13.41l-7.17 7.17a2 2 0 0 1-2.83 0L2 12V2h10l8.59 8.59a2 2 0 0 1 0 2.82z"></path>
                  <line x1="7" y1="7" x2="7" y2="7"></line>
                </svg>
              </div>
              <h3>Умное переименование</h3>
              <p>Безопасное переименование деталей, создание независимых копий и сохранение ссылочной целостности сборки.</p>
            </div>
          </div>
          
          <!-- Feature 8 -->
          <div class="feature-card" id="feat-pack">
            <div class="feature-image-container" onclick="openLightbox('assets/img/ztool_8.png', 'Быстрая упаковка')">
              <img src="assets/img/ztool_8.png" alt="Быстрая упаковка SWTool" class="feature-image" loading="lazy">
              <div class="feature-image-overlay">
                <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="zoom-icon"><circle cx="11" cy="11" r="8"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line><line x1="11" y1="8" x2="11" y2="14"></line><line x1="8" y1="11" x2="14" y2="11"></line></svg>
              </div>
            </div>
            <div class="feature-card-content">
              <div class="feature-icon-wrapper">
                <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                  <polyline points="22 12 16 12 14 15 10 15 8 12 2 12"></polyline>
                  <path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"></path>
                </svg>
              </div>
              <h3>Быстрая упаковка</h3>
              <p>Мгновенная архивация сборок и чертежей в один файл с поддержкой фильтрации по типам компонентов и узлам.</p>
            </div>
          </div>
          
          <!-- Feature 9 -->
          <div class="feature-card" id="feat-bom">
            <div class="feature-image-container" onclick="openLightbox('assets/img/ztool_9.png', 'Экспорт спецификаций')">
              <img src="assets/img/ztool_9.png" alt="Экспорт спецификаций SWTool" class="feature-image" loading="lazy">
              <div class="feature-image-overlay">
                <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="zoom-icon"><circle cx="11" cy="11" r="8"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line><line x1="11" y1="8" x2="11" y2="14"></line><line x1="8" y1="11" x2="14" y2="11"></line></svg>
              </div>
            </div>
            <div class="feature-card-content">
              <div class="feature-icon-wrapper">
                <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                  <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"></path>
                  <polyline points="14 2 14 8 20 8"></polyline>
                  <line x1="16" y1="13" x2="8" y2="13"></line>
                  <line x1="16" y1="17" x2="8" y2="17"></line>
                  <polyline points="10 9 9 9 8 9"></polyline>
                </svg>
              </div>
              <h3>Экспорт спецификаций</h3>
              <p>Настройка спецификаций BOM и выгрузка таблиц для закупок и производства в Excel с сохранением иерархии деталей.</p>
            </div>
          </div>
          
          <!-- Feature 10 -->
          <div class="feature-card" id="feat-pdf">
            <div class="feature-image-container" onclick="openLightbox('assets/img/ztool_10.png', 'Слияние и сплит PDF')">
              <img src="assets/img/ztool_10.png" alt="Слияние и сплит PDF SWTool" class="feature-image" loading="lazy">
              <div class="feature-image-overlay">
                <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="zoom-icon"><circle cx="11" cy="11" r="8"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line><line x1="11" y1="8" x2="11" y2="14"></line><line x1="8" y1="11" x2="14" y2="11"></line></svg>
              </div>
            </div>
            <div class="feature-card-content">
              <div class="feature-icon-wrapper">
                <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                  <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"></path>
                  <polyline points="14 2 14 8 20 8"></polyline>
                  <path d="M9 15h3a1.5 1.5 0 0 0 0-3H9v6M15 12v6a3 3 0 0 0 0-6z"></path>
                </svg>
              </div>
              <h3>Слияние и сплит PDF</h3>
              <p>Удобные утилиты для пакетной нарезки многостраничных PDF-документов или объединения чертежей проекта в общий файл.</p>
            </div>
          </div>
          
          <!-- Feature 11 -->
          <div class="feature-card" id="feat-custom-buttons">
            <div class="feature-image-container" onclick="openLightbox('assets/img/ztool_11.png', 'Кастомные кнопки')">
              <img src="assets/img/ztool_11.png" alt="Кастомные кнопки SWTool" class="feature-image" loading="lazy">
              <div class="feature-image-overlay">
                <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="zoom-icon"><circle cx="11" cy="11" r="8"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line><line x1="11" y1="8" x2="11" y2="14"></line><line x1="8" y1="11" x2="14" y2="11"></line></svg>
              </div>
            </div>
            <div class="feature-card-content">
              <div class="feature-icon-wrapper">
                <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                  <rect x="3" y="3" width="7" height="7"></rect>
                  <rect x="14" y="3" width="7" height="7"></rect>
                  <rect x="14" y="14" width="7" height="7"></rect>
                  <rect x="3" y="14" width="7" height="7"></rect>
                </svg>
              </div>
              <h3>Кастомные кнопки</h3>
              <p>Возможность добавления до 20 пользовательских ярлыков на панель SolidWorks для вызова макросов, папок или сайтов.</p>
            </div>
          </div>
          
          <!-- Feature 12 -->
          <div class="feature-card" id="feat-regex">
            <div class="feature-image-container" onclick="openLightbox('assets/img/ztool_12.png', 'Разбор имен по регуляркам')">
              <img src="assets/img/ztool_12.png" alt="Разбор имен по регуляркам SWTool" class="feature-image" loading="lazy">
              <div class="feature-image-overlay">
                <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="zoom-icon"><circle cx="11" cy="11" r="8"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line><line x1="11" y1="8" x2="11" y2="14"></line><line x1="8" y1="11" x2="14" y2="11"></line></svg>
              </div>
            </div>
            <div class="feature-card-content">
              <div class="feature-icon-wrapper">
                <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                  <circle cx="12" cy="12" r="10"></circle>
                  <line x1="8" y1="12" x2="16" y2="12"></line>
                  <line x1="12" y1="8" x2="12" y2="16"></line>
                </svg>
              </div>
              <h3>Разбор имен по регуляркам</h3>
              <p>Использование RegExp-шаблонов для умного расщепления названий файлов и автоматического заполнения свойств деталей.</p>
            </div>
          </div>

          <!-- Feature 13 -->
          <div class="feature-card" id="feat-bom-report">
            <div class="feature-image-container" onclick="openLightbox('assets/img/ztool_13.png', 'BOM отчеты')">
              <img src="assets/img/ztool_13.png" alt="BOM отчеты SWTool" class="feature-image" loading="lazy">
              <div class="feature-image-overlay">
                <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="zoom-icon"><circle cx="11" cy="11" r="8"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line><line x1="11" y1="8" x2="11" y2="14"></line><line x1="8" y1="11" x2="14" y2="11"></line></svg>
              </div>
            </div>
            <div class="feature-card-content">
              <div class="feature-icon-wrapper">
                <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                  <rect x="3" y="3" width="18" height="18" rx="2" ry="2"></rect>
                  <line x1="3" y1="9" x2="21" y2="9"></line>
                  <line x1="9" y1="21" x2="9" y2="9"></line>
                </svg>
              </div>
              <h3>BOM отчеты</h3>
              <p>Профессиональные BOM-отчеты с поддержкой одноуровневого, многоуровневого, верхнего уровня и режима деталей.</p>
            </div>
          </div>
          
        </div>
      </div>
    </section>

    <!-- Integration Guide / How it Works -->
    <section class="section integration" id="integration">
      <div class="container integration-grid">
        <div class="integration-info">
          <h2 class="section-title" style="text-align:left;">Быстрый запуск в SolidWorks</h2>
          <p class="section-subtitle" style="text-align:left; margin-left:0; margin-bottom:48px;">Начать работу с SWTool можно за несколько минут. Плагин полностью интегрируется в меню вашей CAD-системы.</p>
          
          <div class="step-list">
            <div class="step-item">
              <div class="step-num">1</div>
              <div class="step-content">
                <h4>Скачайте и установите</h4>
                <p>Загрузите официальный установщик SWTool для Windows и следуйте простым инструкциям на экране.</p>
              </div>
            </div>
            <div class="step-item">
              <div class="step-num">2</div>
              <div class="step-content">
                <h4>Получите лицензионный ключ</h4>
                <p>Используйте бесплатный демо-режим или активируйте персональный ключ лицензии для работы без ограничений.</p>
              </div>
            </div>
            <div class="step-item">
              <div class="step-num">3</div>
              <div class="step-content">
                <h4>Наслаждайтесь автоматизацией</h4>
                <p>SWTool автоматически встроится в панель инструментов SolidWorks. Запускайте плагин в один клик.</p>
              </div>
            </div>
          </div>
        </div>
        <div class="integration-visual">
          <div class="hero-mockup-wrapper">
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 450 250" width="100%" height="auto" style="background:#090f1d; border-radius:12px;">
              <rect width="450" height="25" fill="#0f172a" />
              <text x="225" y="17" fill="#64748b" font-size="10" text-anchor="middle" font-family="sans-serif">Окно Активации SWTool</text>
              
              <!-- Simulated Form -->
              <rect x="50" y="50" width="350" height="150" rx="6" fill="#111827" stroke="#1e293b" />
              <text x="70" y="80" fill="#94a3b8" font-size="9" font-family="sans-serif">Введите ключ активации:</text>
              <rect x="70" y="90" width="310" height="22" rx="4" fill="#0f172a" stroke="#1e293b" />
              <text x="80" y="104" fill="#64748b" font-size="8" font-family="sans-serif">XXXX-XXXX-XXXX-XXXX</text>
              
              <text x="70" y="132" fill="#94a3b8" font-size="9" font-family="sans-serif">Пароль переноса лицензии:</text>
              <rect x="70" y="142" width="310" height="22" rx="4" fill="#0f172a" stroke="#1e293b" />
              <text x="80" y="156" fill="#64748b" font-size="8" font-family="sans-serif">••••••••</text>
              
              <!-- Buttons -->
              <rect x="70" y="176" width="100" height="20" rx="10" fill="rgba(6, 182, 212, 0.15)" />
              <text x="120" y="188" fill="#06b6d4" font-size="8" font-family="sans-serif" font-weight="bold" text-anchor="middle">Демо-режим</text>
              
              <rect x="280" y="176" width="100" height="20" rx="10" fill="#10b981" />
              <text x="330" y="188" fill="#ffffff" font-size="8" font-family="sans-serif" font-weight="bold" text-anchor="middle">Активировать</text>
              
              <text x="225" y="225" fill="#475569" font-size="8" font-family="sans-serif" text-anchor="middle">Поддерживает SolidWorks 2012 — 2026</text>
            </svg>
          </div>
        </div>
      </div>
    </section>

    <!-- FAQ Section -->
    <section class="section FAQ" id="faq">
      <div class="container">
        <h2 class="section-title">Часто задаваемые вопросы</h2>
        <p class="section-subtitle">Ответы на популярные вопросы о лицензировании, установке и возможностях плагина SWTool.</p>
        
        <div class="faq-grid">
          
          <div class="faq-item">
            <button class="faq-question">
              Лицензия привязывается к одному компьютеру?
              <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" class="faq-icon"><polyline points="6 9 12 15 18 9"></polyline></svg>
            </button>
            <div class="faq-answer">
              <div class="faq-answer-content">
                Да, персональная лицензия привязывается к аппаратному идентификатору (Hardware Fingerprint) вашего ПК на основе серийного номера BIOS и системных настроек. Однако в плагин встроена возможность деактивации лицензии, что позволяет легко перенести её на другой компьютер (например, при апгрейде железа или смене рабочего места).
              </div>
            </div>
          </div>
          
          <div class="faq-item">
            <button class="faq-question">
              Какие версии SolidWorks поддерживает плагин?
              <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" class="faq-icon"><polyline points="6 9 12 15 18 9"></polyline></svg>
            </button>
            <div class="faq-answer">
              <div class="faq-answer-content">
                SWTool официально поддерживает 64-битные версии SolidWorks начиная с SolidWorks 2012 вплоть до самых современных версий SolidWorks 2026.
              </div>
            </div>
          </div>
          
          <div class="faq-item">
            <button class="faq-question">
              Нужен ли постоянный доступ к интернету?
              <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" class="faq-icon"><polyline points="6 9 12 15 18 9"></polyline></svg>
            </button>
            <div class="faq-answer">
              <div class="faq-answer-content">
                Нет. Доступ к интернету требуется только один раз — в момент ввода ключа активации на сервере лицензирования. После успешной активации лицензионный файл сохраняется локально в зашифрованном виде, и плагин может использоваться полностью в оффлайн-режиме без подключения к сети.
              </div>
            </div>
          </div>

          <div class="faq-item">
            <button class="faq-question">
              Как работает демонстрационный режим?
              <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" class="faq-icon"><polyline points="6 9 12 15 18 9"></polyline></svg>
            </button>
            <div class="faq-answer">
              <div class="faq-answer-content">
                Демонстрационный режим активируется одним кликом прямо в окне запуска плагина без ввода каких-либо ключей. В демо-режиме доступен абсолютно весь функционал без ограничений по количеству деталей, но время каждой рабочей сессии ограничено 3 минутами. По истечении таймера плагин закрывается. Количество запусков демо-сессий не ограничено.
              </div>
            </div>
          </div>
          
        </div>
      </div>
    </section>

    <!-- Pricing Section -->
    <section class="section" id="pricing">
      <div class="container">
        <h2 class="section-title">Гибкие тарифы под любые задачи</h2>
        <p class="section-subtitle">Выберите подходящую версию для ваших проектов — от бесплатного ознакомления до полноценного использования на предприятии.</p>
        
        <div class="pricing-grid">
          
          <!-- Plan 1 -->
          <div class="price-card" id="plan-trial">
            <div class="price-header">
              <h3>Ознакомительная</h3>
              <p class="price-desc">Бесплатный демонстрационный режим.</p>
            </div>
            <div class="price-val">0 <span>₽</span></div>
            <ul class="price-features">
              <li>
                <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"></polyline></svg>
                Доступен полный функционал
              </li>
              <li>
                <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"></polyline></svg>
                Без ввода ключа активации
              </li>
              <li>
                <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"></polyline></svg>
                Сессия до 3 минут
              </li>
            </ul>
            <a href="#download" class="btn btn-secondary" id="btn-buy-trial">Скачать плагин</a>
          </div>
          
          <!-- Plan 2 -->
          <div class="price-card popular" id="plan-personal">
            <div class="badge-popular">Популярно</div>
            <div class="price-header">
              <h3>Персональная</h3>
              <p class="price-desc">Лицензия на 1 рабочий компьютер.</p>
            </div>
            <div class="price-val">3 200 <span>₽</span></div>
            <ul class="price-features">
              <li>
                <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"></polyline></svg>
                Привязка к аппаратному ПК
              </li>
              <li>
                <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"></polyline></svg>
                Безлимитное время сессий
              </li>
              <li>
                <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"></polyline></svg>
                Возможность переноса лицензии
              </li>
              <li>
                <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"></polyline></svg>
                Бесплатные обновления
              </li>
            </ul>
            <a href="mailto:sales@z-tool.ru?subject=Покупка персональной лицензии SWTool" class="btn btn-accent" id="btn-buy-personal">Купить лицензию</a>
          </div>
          
          <!-- Plan 3 -->
          <div class="price-card" id="plan-corporate">
            <div class="price-header">
              <h3>Коммерческая</h3>
              <p class="price-desc">Пакет лицензий для проектных групп.</p>
            </div>
            <div class="price-val">Договорная <span></span></div>
            <ul class="price-features">
              <li>
                <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"></polyline></svg>
                Множественные активации
              </li>
              <li>
                <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"></polyline></svg>
                Оплата по счету / договор
              </li>
              <li>
                <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"></polyline></svg>
                Персональная техподдержка
              </li>
              <li>
                <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"></polyline></svg>
                Скидки при заказе от 5 лицензий
              </li>
            </ul>
            <a href="mailto:sales@z-tool.ru?subject=Запрос коммерческой лицензии SWTool" class="btn btn-secondary" id="btn-buy-corporate">Связаться с нами</a>
          </div>
          
        </div>
      </div>
    </section>

    <!-- Download Section -->
    <section class="section download" id="download">
      <div class="container">
        <div class="download-panel">
          <div class="glow-orb glow-orb-1"></div>
          <h2>Готовы начать автоматизацию?</h2>
          <p>Скачайте плагин SWTool и оцените удобство автоматизированного файлового менеджмента и пакетной печати прямо сейчас.</p>
          <div class="download-actions">
            <a href="php/download.php" class="btn btn-accent btn-large" id="btn-panel-download">Скачать установщик (.EXE)</a>
            <span class="download-meta">Совместимо с Windows 7/10/11 и SolidWorks 2012–2026.</span>
          </div>
        </div>
      </div>
    </section>

  </main>

  <!-- Footer -->
  <footer class="footer" id="contact">
    <div class="container">
      <div class="footer-grid">
        <div class="footer-about">
          <img src="assets/logo.svg" alt="SWTool" class="footer-logo" width="120" height="32">
          <p>SWTool — высокоэффективное вспомогательное дополнение для SolidWorks, разработанное опытными инженерами с целью избавить проектировщиков от рутины и ускорить выпуск КД.</p>
        </div>
        
        <div class="footer-links">
          <h3>Навигация</h3>
          <ul>
            <li><a href="#hero">Главная</a></li>
            <li><a href="#features">Возможности</a></li>
            <li><a href="#integration">Как начать</a></li>
            <li><a href="#faq">FAQ</a></li>
            <li><a href="#pricing">Тарифы</a></li>
          </ul>
        </div>
        
        <div class="footer-contact">
          <h3>Контакты и поддержка</h3>
          <p>Email: <a href="mailto:support@z-tool.ru" id="footer-email">support@z-tool.ru</a></p>
          <p>Telegram: <a href="https://t.me/ztool_support" target="_blank" id="footer-telegram">@ztool_support</a></p>
          <p>Для покупки лицензий: <a href="mailto:sales@z-tool.ru" id="footer-sales">sales@z-tool.ru</a></p>
        </div>
      </div>
      
      <div class="footer-copyright">
        <p>&copy; <?php echo date('Y'); ?> SWTool. Все права защищены. Разработано для автоматизации САПР.</p>
      </div>
    </div>
  </footer>

  <!-- Lightbox Modal for Screenshots -->
  <div class="lightbox" id="lightbox">
    <div class="lightbox-content">
      <button class="lightbox-close" id="lightbox-close" aria-label="Закрыть">&times;</button>
      <img class="lightbox-img" id="lightbox-img" src="" alt="Скриншот SWTool">
      <div class="lightbox-caption" id="lightbox-caption"></div>
    </div>
  </div>

  <!-- JS -->
  <script src="js/landing.js"></script>
</body>
</html>
