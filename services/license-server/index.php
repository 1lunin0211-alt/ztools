<?php
// ZTool Russian Landing Page - Main Entry Point
?>
<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  
  <title>ZTool — Профессиональный плагин для SolidWorks | Автоматизация проектирования</title>
  
  <meta name="keywords" content="ZTool, плагин SolidWorks, SolidWorks автоматизация, надстройка SolidWorks, пакетная печать SolidWorks, спецификация BOM SolidWorks, переименование компонентов SolidWorks">
  <meta name="description" content="Ускорьте проектирование в SolidWorks в 10 раз с помощью ZTool. Пакетная печать чертежей, умный файловый менеджер, генерация BOM-отчетов, переименование компонентов с сохранением связей и пакетная конвертация файлов.">
  
  <!-- Favicon -->
  <link href="assets/logo.svg" rel="icon" type="image/svg+xml">
  
  <!-- CSS -->
  <link href="css/landing.css" rel="stylesheet">
</head>
<body>

  <!-- Header -->
  <header class="header" id="header">
    <div class="container header-container">
      <a href="#" class="logo-link">
        <img src="assets/logo.svg" alt="ZTool Logo" width="130" height="35">
      </a>
      
      <nav class="nav" id="nav-menu">
        <a href="#features" class="nav-link">Возможности</a>
        <a href="#integration" class="nav-link">Как это работает</a>
        <a href="#pricing" class="nav-link">Тарифы</a>
        <a href="#download" class="nav-link">Скачать</a>
        <a href="#contact" class="nav-link">Контакты</a>
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
            <!-- Simulated Premium Dark UI showing SolidWorks Interface + ZTool panel -->
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 500 320" width="100%" height="auto" style="background:#090f1d; border-radius:12px;">
              <!-- Window header -->
              <rect width="500" height="25" fill="#0f172a" />
              <circle cx="15" cy="12" r="4" fill="#ef4444" />
              <circle cx="27" cy="12" r="4" fill="#eab308" />
              <circle cx="39" cy="12" r="4" fill="#22c55e" />
              <text x="250" y="17" fill="#64748b" font-size="10" text-anchor="middle" font-family="sans-serif">SolidWorks 2026 + ZTool AddIn</text>
              
              <!-- Left Sidebar: Assembly Tree -->
              <rect x="0" y="25" width="120" height="295" fill="#111827" />
              <rect x="10" y="35" width="100" height="12" rx="3" fill="#1e293b" />
              <text x="15" y="44" fill="#94a3b8" font-size="8" font-family="sans-serif">📦 Сборка_Редуктор</text>
              <rect x="20" y="55" width="90" height="10" rx="2" fill="#1e293b" />
              <text x="25" y="63" fill="#64748b" font-size="7" font-family="sans-serif">⚙️ Вал_Ведомый.SLDPRT</text>
              <rect x="20" y="70" width="90" height="10" rx="2" fill="#1e293b" />
              <text x="25" y="78" fill="#64748b" font-size="7" font-family="sans-serif">⚙️ Шестерня.SLDPRT</text>
              <rect x="20" y="85" width="90" height="10" rx="2" fill="#1e293b" />
              <text x="25" y="93" fill="#64748b" font-size="7" font-family="sans-serif">⚙️ Корпус.SLDPRT</text>
              
              <!-- Top Toolbar (Ribbon) with ZTool Tab -->
              <rect x="120" y="25" width="380" height="40" fill="#0f172a" />
              <!-- Tabs -->
              <text x="140" y="40" fill="#475569" font-size="8" font-family="sans-serif" font-weight="bold">Эскиз</text>
              <text x="180" y="40" fill="#475569" font-size="8" font-family="sans-serif" font-weight="bold">Элементы</text>
              <rect x="230" y="28" width="50" height="34" rx="3" fill="#1e293b" />
              <text x="255" y="40" fill="#06b6d4" font-size="8" font-family="sans-serif" font-weight="bold" text-anchor="middle">ZTool</text>
              
              <!-- ZTool Toolbar buttons -->
              <rect x="130" y="48" width="30" height="12" rx="2" fill="#06b6d4" opacity="0.15" />
              <text x="145" y="57" fill="#06b6d4" font-size="6" font-family="sans-serif" text-anchor="middle">Печать</text>
              
              <rect x="165" y="48" width="35" height="12" rx="2" fill="#8b5cf6" opacity="0.15" />
              <text x="182.5" y="57" fill="#8b5cf6" font-size="6" font-family="sans-serif" text-anchor="middle">BOM отчет</text>
              
              <rect x="205" y="48" width="40" height="12" rx="2" fill="#1e293b" />
              <text x="225" y="57" fill="#94a3b8" font-size="6" font-family="sans-serif" text-anchor="middle">Имя файлов</text>
              
              <!-- Main Graphical Area showing 3D mechanical draft outline -->
              <rect x="120" y="65" width="380" height="255" fill="#020617" />
              <path d="M 220,180 L 380,180 L 350,110 L 250,110 Z" fill="none" stroke="#1e293b" stroke-width="2" />
              <path d="M 230,170 L 370,170 L 345,120 L 255,120 Z" fill="none" stroke="url(#emblemGrad)" stroke-width="1.5" />
              <circle cx="300" cy="145" r="20" fill="none" stroke="#8b5cf6" stroke-width="1.5" stroke-dasharray="3,3" />
              <line x1="300" y1="110" x2="300" y2="180" stroke="#64748b" stroke-width="1" stroke-dasharray="5,5" />
              <line x1="210" y1="145" x2="390" y2="145" stroke="#64748b" stroke-width="1" stroke-dasharray="5,5" />
              
              <!-- Pop-up ZTool interface card overlay -->
              <rect x="310" y="80" width="170" height="220" rx="8" fill="#0b1329" stroke="url(#emblemGrad)" stroke-width="1" />
              <text x="320" y="96" fill="#f8fafc" font-size="9" font-family="sans-serif" font-weight="bold">Инструменты ZTool</text>
              <line x1="320" y1="104" x2="470" y2="104" stroke="#1e293b" stroke-width="1" />
              
              <!-- Features checklist inside overlay -->
              <text x="335" y="125" fill="#f8fafc" font-size="8" font-family="sans-serif">⚙️ Пакетное переименование</text>
              <text x="335" y="145" fill="#f8fafc" font-size="8" font-family="sans-serif">📄 Генерация спецификации</text>
              <text x="335" y="165" fill="#f8fafc" font-size="8" font-family="sans-serif">🖨️ Авто-определение формата</text>
              <text x="335" y="185" fill="#f8fafc" font-size="8" font-family="sans-serif">📂 Конвертация PDF/STEP/DWG</text>
              <text x="335" y="205" fill="#f8fafc" font-size="8" font-family="sans-serif">🔗 Обновление ссылок деталей</text>
              
              <!-- Run Button -->
              <rect x="320" y="260" width="150" height="25" rx="12.5" fill="url(#emblemGrad)" />
              <text x="395" y="276" fill="#ffffff" font-size="9" font-family="sans-serif" font-weight="bold" text-anchor="middle">Запустить обработку</text>
            </svg>
          </div>
        </div>
      </div>
    </section>

    <!-- Features Section -->
    <section class="section" id="features">
      <div class="container">
        <h2 class="section-title">Все необходимые инструменты в одном плагине</h2>
        <p class="section-subtitle">ZTool содержит мощный набор функций для инженеров-конструкторов, автоматизирующих работу с файлами, чертежами и спецификациями.</p>
        
        <div class="features-grid">
          
          <!-- Feature 1 -->
          <div class="feature-card" id="feat-file-mgmt">
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
          
          <!-- Feature 2 -->
          <div class="feature-card" id="feat-conversion">
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
          
          <!-- Feature 3 -->
          <div class="feature-card" id="feat-printing">
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
          
          <!-- Feature 4 -->
          <div class="feature-card" id="feat-frames">
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
          
          <!-- Feature 5 -->
          <div class="feature-card" id="feat-references">
            <div class="feature-icon-wrapper">
              <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"></path>
                <path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"></path>
              </svg>
            </div>
            <h3>Замена связей</h3>
            <p>Массовое обновление и подмена ссылок на сопряженные детали и узлы внутри сборок SolidWorks без потери сопряжений.</p>
          </div>
          
          <!-- Feature 6 -->
          <div class="feature-card" id="feat-drawing-sync">
            <div class="feature-icon-wrapper">
              <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <path d="M21.5 2v6h-6M21.34 15.57a10 10 0 1 1-.57-8.38l5.67-5.67"></path>
              </svg>
            </div>
            <h3>Синхронизация имен</h3>
            <p>Пакетное переименование файлов чертежей (`.SLDDRW`) в соответствии с именами связанных 3D-моделей деталей или сборок.</p>
          </div>
          
          <!-- Feature 7 -->
          <div class="feature-card" id="feat-renaming">
            <div class="feature-icon-wrapper">
              <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <path d="M20.59 13.41l-7.17 7.17a2 2 0 0 1-2.83 0L2 12V2h10l8.59 8.59a2 2 0 0 1 0 2.82z"></path>
                <line x1="7" y1="7" x2="7" y2="7"></line>
              </svg>
            </div>
            <h3>Умное переименование</h3>
            <p>Безопасное переименование деталей, создание независимых копий и сохранение ссылочной целостности сборки.</p>
          </div>
          
          <!-- Feature 8 -->
          <div class="feature-card" id="feat-pack">
            <div class="feature-icon-wrapper">
              <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <polyline points="22 12 16 12 14 15 10 15 8 12 2 12"></polyline>
                <path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"></path>
              </svg>
            </div>
            <h3>Быстрая упаковка</h3>
            <p>Мгновенная архивация сборок и чертежей в один файл с поддержкой фильтрации по типам компонентов и узлам.</p>
          </div>
          
          <!-- Feature 9 -->
          <div class="feature-card" id="feat-bom">
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
            <p>Настройка множественных правил вывода спецификаций и мгновенная выгрузка BOM-таблиц для закупок и производства.</p>
          </div>
          
          <!-- Feature 10 -->
          <div class="feature-card" id="feat-pdf">
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
          
          <!-- Feature 11 -->
          <div class="feature-card" id="feat-custom-buttons">
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
          
          <!-- Feature 12 -->
          <div class="feature-card" id="feat-regex">
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
      </div>
    </section>

    <!-- Integration Guide / How it Works -->
    <section class="section integration" id="integration">
      <div class="container integration-grid">
        <div class="integration-info">
          <h2 class="section-title" style="text-align:left;">Быстрый запуск в SolidWorks</h2>
          <p class="section-subtitle" style="text-align:left; margin-left:0; margin-bottom:48px;">Начать работу с ZTool можно за несколько минут. Плагин полностью интегрируется в меню вашей CAD-системы.</p>
          
          <div class="step-list">
            <div class="step-item">
              <div class="step-num">1</div>
              <div class="step-content">
                <h4>Скачайте и установите</h4>
                <p>Загрузите официальный установщик ZTool для Windows и следуйте простым инструкциям на экране.</p>
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
                <p>ZTool автоматически встроится в панель инструментов SolidWorks. Запускайте плагин в один клик.</p>
              </div>
            </div>
          </div>
        </div>
        <div class="integration-visual">
          <div class="hero-mockup-wrapper">
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 450 250" width="100%" height="auto" style="background:#090f1d; border-radius:12px;">
              <rect width="450" height="25" fill="#0f172a" />
              <text x="225" y="17" fill="#64748b" font-size="10" text-anchor="middle" font-family="sans-serif">Окно Активации ZTool</text>
              
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
              
              <rect x="280" y="176" width="100" height="20" rx="10" fill="url(#emblemGrad)" />
              <text x="330" y="188" fill="#ffffff" font-size="8" font-family="sans-serif" font-weight="bold" text-anchor="middle">Активировать</text>
              
              <text x="225" y="225" fill="#475569" font-size="8" font-family="sans-serif" text-anchor="middle">Поддерживает SolidWorks 2012 — 2026</text>
            </svg>
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
            <a href="https://item.taobao.com/item.htm?id=638150915723" target="_blank" class="btn btn-primary" id="btn-buy-personal">Купить лицензию</a>
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
            <a href="mailto:mail@z-tool.cn" class="btn btn-secondary" id="btn-buy-corporate">Связаться с нами</a>
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
          <p>Скачайте плагин ZTool и оцените удобство автоматизированного файлового менеджмента и пакетной печати прямо сейчас.</p>
          <div class="download-actions">
            <a href="php/download.php" class="btn btn-primary btn-large" id="btn-panel-download">Скачать установщик (.EXE)</a>
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
          <img src="assets/logo.svg" alt="ZTool" class="footer-logo" width="120" height="32">
          <p>ZTool — высокоэффективное вспомогательное дополнение для SolidWorks, разработанное опытными инженерами с целью избавить проектировщиков от рутины и ускорить выпуск КД.</p>
        </div>
        
        <div class="footer-links">
          <h3>Навигация</h3>
          <ul>
            <li><a href="#hero">Главная</a></li>
            <li><a href="#features">Возможности</a></li>
            <li><a href="#integration">Как начать</a></li>
            <li><a href="#pricing">Тарифы</a></li>
            <li><a href="#download">Скачать</a></li>
          </ul>
        </div>
        
        <div class="footer-contact">
          <h3>Контакты и поддержка</h3>
          <p>Email: <a href="mailto:mail@z-tool.cn" id="footer-email">mail@z-tool.cn</a></p>
          <p>Веб-сайт поддержки: <a href="http://www.z-tool.cn" target="_blank" id="footer-site">www.z-tool.cn</a></p>
          <p>Для покупки лицензии: <a href="https://item.taobao.com/item.htm?id=638150915723" target="_blank" id="footer-taobao">Taobao Store</a></p>
          <p>QQ: 287926418 | Группа QQ: 823539419</p>
        </div>
      </div>
      
      <div class="footer-copyright">
        <p>&copy; <?php echo date('Y'); ?> ZTool. Все права защищены. Разработано для автоматизации САПР.</p>
      </div>
    </div>
  </footer>

  <!-- JS -->
  <script src="js/landing.js"></script>
</body>
</html>
