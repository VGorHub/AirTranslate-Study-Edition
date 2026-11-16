---
name: AirTranslate Study Edition Web
description: Браузерная стенограмма для чтения и разбора занятий
colors:
  primary: "#126e79"
  primary-dark: "#38c2cf"
  primary-foreground: "#fff"
  primary-foreground-dark: "#092125"
  secondary: "#e0f1f2"
  secondary-dark: "#183a3f"
  secondary-foreground: "#155963"
  secondary-foreground-dark: "#91e3e9"
  ring: "#167d8b"
  ring-dark: "#38c2cf"
  select: "#c4e9ed"
  select-dark: "#25575f"
  background: "#fff"
  background-dark: "#15181b"
  canvas: "#f4f5f7"
  canvas-dark: "#111316"
  foreground: "#20282b"
  foreground-dark: "#e9edef"
  muted: "#edf1f2"
  muted-dark: "#242a2e"
  muted-foreground: "#53636a"
  muted-foreground-dark: "#a8b5ba"
  border: "#dce4e6"
  border-dark: "#30383d"
  input: "#b0bec2"
  input-dark: "#55666b"
  live: "#12733e"
  live-dark: "#60d897"
  warning: "#805600"
  warning-dark: "#f2bd63"
  destructive: "#9a311a"
  destructive-dark: "#ff9e89"
typography:
  headline:
    fontFamily: "Inter Variable, system-ui, sans-serif"
    fontWeight: 625
    lineHeight: 1.1
    letterSpacing: "-0.038em"
  body:
    fontFamily: "PT Serif, Georgia, serif"
    fontWeight: 400
    lineHeight: 1.48
  translation:
    fontFamily: "Inter Variable, system-ui, sans-serif"
    fontSize: "0.925rem"
    fontWeight: 400
    lineHeight: 1.62
  control:
    fontFamily: "Inter Variable, system-ui, sans-serif"
    fontSize: "0.875rem"
    fontWeight: 500
    lineHeight: "1.25rem"
  session-date:
    fontFamily: "Inter Variable, system-ui, sans-serif"
    fontSize: "0.875rem"
    fontWeight: 600
    lineHeight: 1.4
  timestamp:
    fontFamily: "Inter Variable, system-ui, sans-serif"
    fontSize: "0.8rem"
    fontWeight: 400
    lineHeight: 1.5
rounded:
  control: "0.5rem"
spacing:
  small-gap: "4px"
  icon-gap: "8px"
  row-gap: "12px"
  translation-gap: "6px"
  transcript-row: "19px"
components:
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.primary-foreground}"
    typography: "{typography.control}"
    rounded: "{rounded.control}"
    padding: "0 0.625rem"
    height: "2.25rem"
  button-outline:
    backgroundColor: "{colors.background}"
    textColor: "{colors.foreground}"
    typography: "{typography.control}"
    rounded: "{rounded.control}"
    padding: "0 0.625rem"
    height: "2.25rem"
  button-secondary:
    backgroundColor: "{colors.secondary}"
    textColor: "{colors.secondary-foreground}"
    typography: "{typography.control}"
    rounded: "{rounded.control}"
    padding: "0 0.625rem"
    height: "2rem"
  button-ghost:
    rounded: "{rounded.control}"
    size: "1.75rem"
  search:
    backgroundColor: "{colors.background}"
    textColor: "{colors.foreground}"
    rounded: "{rounded.control}"
    padding: "0 9px"
    height: "36px"
  switch-checked:
    backgroundColor: "{colors.primary}"
    width: "32px"
    height: "18.4px"
  switch-unchecked:
    backgroundColor: "{colors.input}"
    width: "32px"
    height: "18.4px"
  session-link:
    textColor: "{colors.foreground}"
    rounded: "{rounded.control}"
    padding: "10px 12px"
  session-link-current:
    backgroundColor: "{colors.secondary}"
    textColor: "{colors.secondary-foreground}"
    rounded: "{rounded.control}"
    padding: "10px 12px"
  transcript-row:
    textColor: "{colors.foreground}"
    typography: "{typography.body}"
    padding: "19px 0"
---

# AirTranslate Study Edition Web

## Overview

**Creative North Star: "Конспект занятия"**

Длинную стенограмму читают как заметки. Крупный оригинал задаёт ход чтения, перевод остаётся под ним, а время вынесено в отдельную колонку. Архив и управление помещаются рядом с текстом.

Правила относятся к веб-интерфейсу Study Edition. Нейтральные поверхности, бирюза и отдельные цвета состояний продолжают нативный AirTranslate. Типографику и геометрию веб-версии задаёт её собственный CSS. [Нативная палитра](Sources/AirTranslate/Views/AirTranslateDesign.swift) · [Стили веб-интерфейса](Web/src/index.css)

**Key Characteristics:**

- Оригинал набран PT Serif, интерфейс и перевод набраны Inter.
- Строки стенограммы разделены тонкими линиями.
- Светлая и тёмная темы сохраняют одинаковую иерархию.

## Colors

### Primary

- Глубокая бирюза в светлой теме и светлая бирюза в тёмной выделяют возврат к последней фразе и включённые переключатели. Мягкая бирюзовая подложка отмечает выбранное занятие и переход к живой записи.
- Бирюзовая обводка показывает фокус. Отдельный мягкий оттенок сохраняет читаемость выделенного текста.

### Neutral

- Основная поверхность держит текст стенограммы, холодный оттенок фона выделяет архив. Тонкие границы разделяют панели и реплики. Приглушённый фон используется при наведении, приглушённый текст служит для метаданных и перевода.

**The State Color Rule.** Зелёный обозначает активную запись или установленное подключение. Янтарный показывает паузу, прерывание записи и подключение в процессе. Подпись или значок также передаёт состояние. Сообщение об ошибке использует красный.

До выбора пользователя тема следует системному оформлению. Кнопка темы сохраняет явный выбор между светлой и тёмной палитрой.

## Typography

- Заголовок занятия набран Inter Variable с относительным к ширине окна размером (`clamp(1.85rem, 3.2vw, 2.6rem)`), плотным межстрочным интервалом и весом 625.
- Оригинал набран PT Serif (400, `clamp(1.2rem, 2vw, 1.4rem)`, межстрочный интервал 1,48). Локально упакованный шрифт в случае необходимости заменяется Georgia.
- Перевод, метаданные и инструменты используют Inter Variable. Перевод меньше оригинала и набран приглушённым цветом. Время в стенограмме и час начала занятия в архиве используют цифры одинаковой ширины.

**The Transcript Hierarchy Rule.** Сохраняйте оригинал первым и размещайте доступный перевод сразу под ним. Состояние распознавания имеет собственный блок, где исходный текст приглушён.

## Layout

На широком экране шапка занимает всю ширину, а ниже история слева соседствует с областью чтения. Ширина истории меняется от 210 до 278 px. Заголовок со средствами управления и прокручиваемая стенограмма выровнены по одной области шириной до 930 px, с полями от 18 до 72 px. В строке стенограммы за отступом времени шириной 64 px следуют текст и кнопка копирования.

При ширине до 780 px история раскрывается кнопкой в шапке над областью чтения. До 480 px поиск занимает отдельную строку инструментов, а время и копирование располагаются над текстом каждой реплики.

## Elevation & Depth

Матовые поверхности разделены цветом и линиями толщиной 1 px. Контрастная плашка обратной связи появляется поверх стенограммы. Для клавиатурного фокуса используются бирюзовая обводка и кольцо.

## Shapes

Кнопки, поле поиска и ссылки архива имеют скругление 0,5 rem. Переключатели и индикатор подключения полностью закруглены. Реплики образуют непрерывный список с прямыми горизонтальными разделителями.

## Components

### Buttons

Бирюзовая кнопка возвращает к последней фразе, пока пользователь читает выше. Светлая бирюзовая кнопка в архиве открывает живую запись. Копирование всего текста использует контурную кнопку. Копирование фразы и вспомогательные команды используют прозрачную кнопку с заливкой при наведении. Кнопки без текста имеют доступное имя.

### Search and switches

Поиск объединяет значок, поле и кнопку очистки одной рамкой. Клавиатурный фокус обводит всё поле. Пара переключателей держит подписи рядом с дорожками, а включённое состояние обозначено положением бегунка и бирюзой.

### Session navigation

Дата набрана полужирным, время и языки расположены второй строкой. Выбранное занятие отмечено мягкой бирюзой и `aria-current`. На узком экране список раскрывается над стенограммой.

### Transcript row

Оригинал и перевод остаются отдельными выделяемыми абзацами с атрибутами языка. У подтверждённой реплики постоянный ключ, отметка времени и копирование. Если время приблизительное, рядом отображается знак «≈». Временные реплики показываются ниже подтверждённых под заголовком «Распознаётся».

## Do's and Don'ts

- Do keep color roles consistent in light and dark themes.
- Do keep transcript text selectable and give controls visible focus and accessible names.
- Do keep translation and metadata visually subordinate to the original transcript.
