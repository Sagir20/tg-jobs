# Критерии поиска. Регулярные выражения — в одинарных кавычках, без экранирования.
@{
    # За сколько последних дней брать вакансии при каждом поиске
    PeriodDays = 7

    # LinkedIn (гостевой поиск, без входа в аккаунт)
    LinkedIn = @(
        @{ Q = 'embedded software engineer'; Loc = 'China';                Country = 'Китай' }
        @{ Q = 'firmware engineer';          Loc = 'China';                Country = 'Китай' }
        @{ Q = 'motor control engineer';     Loc = 'China';                Country = 'Китай' }
        @{ Q = 'EtherCAT';                   Loc = 'China';                Country = 'Китай' }
        @{ Q = 'humanoid robot embedded';    Loc = 'China';                Country = 'Китай' }
        @{ Q = 'embedded software engineer'; Loc = 'Germany';              Country = 'Германия' }
        @{ Q = 'EtherCAT';                   Loc = 'Germany';              Country = 'Германия' }
        @{ Q = 'motor control firmware';     Loc = 'Germany';              Country = 'Германия' }
        @{ Q = 'embedded software engineer'; Loc = 'Netherlands';          Country = 'Нидерланды' }
        @{ Q = 'firmware engineer';          Loc = 'Netherlands';          Country = 'Нидерланды' }
        @{ Q = 'embedded firmware engineer'; Loc = 'Serbia';               Country = 'Сербия' }
        @{ Q = 'embedded engineer';          Loc = 'Armenia';              Country = 'Армения' }
        @{ Q = 'embedded engineer';          Loc = 'Kazakhstan';           Country = 'Казахстан' }
        @{ Q = 'embedded engineer';          Loc = 'United Arab Emirates'; Country = 'ОАЭ' }
        @{ Q = 'embedded engineer';          Loc = 'Cyprus';               Country = 'Кипр' }
        @{ Q = 'embedded firmware engineer'; Loc = 'European Union';       Country = 'Remote (EU)'; Remote = $true }
    )

    # hh.ru (113 = вся Россия, включая Москву; 1 = только Москва)
    HHQueries = @('embedded', 'программист микроконтроллеров', 'встраиваемое программное обеспечение', 'STM32', 'EtherCAT', 'электропривод программист', 'firmware', 'разработчик встраиваемых систем')
    HHAreas   = @('113')

    # Arbeitnow (Германия / Нидерланды)
    ArbeitnowPages     = 10
    ArbeitnowCountries = '^(Германия|Нидерланды)$'

    # Bundesagentur für Arbeit (Германия). Большинство вакансий на немецком — такие получают пометку
    BAQueries = @('Embedded Software', 'Firmware', 'Embedded C', 'Motion Control', 'EtherCAT')

    # Открытые Telegram-каналы с вакансиями (имя после t.me/). Добавляй свои
    TelegramChannels = @('opento_dev', 'young_relocate', 'devjobs')

    # Сколько новых вакансий за запуск открывать целиком (чтение требований)
    # (на GitHub Actions сеть быстрая — 250 описаний читаются за несколько минут)
    MaxDetailsPerRun = 250

    # Фильтр по названию
    TitleInclude  = '(?i)embedded|firmware|встраива|микроконтр|stm32|ethercat|electric drive|электропривод|motor|motion|robot|робот|servo|mcu|bsp|嵌入式|固件|电机|伺服|驱动|机器人|运动控制|mechatronik|antriebs|regelungstechnik|hardwarenah'
    TitleExclude  = '(?i)senior|\bsr\.?\b|staff|lead\b|principal|manager|head of|director|architect|expert|intern\b|praktikum|werkstudent|ведущий|главный|старший|руководител|начальник|архитектор|тимлид|стаж[её]р|продаж|sales|高级|资深|专家|主管|经理|实习|monteur|монтаж|наладчик|конструктор|1с|frontend|java\b|php|node\.?js|typescript|qa\b|тестировщик|тестировани'

    # Оценка
    TitleStrong   = '(?i)ethercat|motion|motor|servo|robot|bldc|\bfoc\b|привод|робот|двигател|伺服|电机|机器人|运动控制|antrieb|mechatron'
    TitleEmbedded = '(?i)embedded|firmware|встраива|микроконтр|stm32|mcu|嵌入式|固件|bsp'
    Skills        = '(?i)stm32|ethercat|freertos|\brtos\b|\busb\b|\bspi\b|i2c|uart|c2000|esp32|twincat|cia ?402|canopen|bldc|\bfoc\b|pmsm|servo|伺服|电机|сервопривод|электропривод'
    YearsRegex    = '(?i)(\d{1,2})\s*\+?\s*(?:(?:-|–|to|bis)\s*\d{1,2}\s*)?\+?\s*(?:years?|yrs|jahre[n]?|年|лет|года)[^.\n]{0,50}?(?:experience|erfahrung|опыт|经验)|(?:experience|erfahrung|опыт|经验)[^.\n]{0,50}?(\d{1,2})\s*\+?\s*(?:years?|yrs|jahre[n]?|年|лет|года)'
    GermanFluent  = '(?i)(fließend|fliessend|verhandlungssicher|sehr gute|C1|C2)[^.\n]{0,40}deutsch|deutsch[^.\n]{0,40}(fließend|fliessend|verhandlungssicher|C1|C2|in wort und schrift)|fluent[^.\n]{0,25}german|german[^.\n]{0,25}(fluent|C1|C2|native)'
    DutchFluent   = '(?i)fluent[^.\n]{0,30}dutch|dutch[^.\n]{0,25}(fluent|native)|vloeiend'
    Defense       = '(?i)бпла|беспилот|оборонно|\bопк\b|двойного назначения|военн|defen[cs]e|military|\buav\b|drone|munition|weapon|ardupilot|\bpx4\b|mavlink|полётн|полетн'

    # Бонус за страну (заграница в приоритете)
    CountryBonus = @{ 'Китай' = 1; 'Германия' = 1; 'Нидерланды' = 1; 'Сербия' = 1; 'Армения' = 1; 'Казахстан' = 1; 'ОАЭ' = 1; 'Кипр' = 1; 'Remote (EU)' = 2 }

    # Зарплата (Россия, ₽ в месяц)
    RuSalaryGood = 230000
    RuSalaryMin  = 170000
}
