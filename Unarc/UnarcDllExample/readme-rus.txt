unarc.dll позволяет распаковывать, тестировать и получать информацию об архивах FreeArc. Для этого она предоставляет
функцию FreeArcExtract, примеры использования которой из разных языков программирования вы можете найти в демо-программах
в соответствующих подкаталогах (CPP, Delphi и т.д.)

Синтаксис вызова:

errcode = FreeArcExtract(callback, command[1], command[2], command[3], ...);

где errcode - код ошибки (FREEARC_OK==0 при успехе, коды ошибок - см. FREEARC_ERRCODE_* в Common.h)
command[1]... - список слов команды, которую должен выполнить unarc, список должен завершаться NULL или "".
Синтаксис поддерживаемых команд можно увидеть, вызвав unarc.exe без параметров.
callback - ваша функция, которая будет вызываться из FreeArcExtract, может быть NULL.

Пример вызова:

int errcode = FreeArcExtract(callback, "x", "-o+", "--", "a.arc", "*.obj", "*.lib", NULL);

С какими параметрами при этом вызывается callback, можно увидеть, откомпилировав и запустив UnarcDllExample.cpp

На настоящий момент это следующие события:

callback("total", totalBytes>>20, totalBytes, "") - вызывается в начале распаковки и передаёт общий размер архива

callback("read",  readBytes>>20,  readBytes,  "") - вызывается многократно в процессе распаковки и передаёт
позицию распаковки в архиве. В сочетании с "total" позволяет рисовать индикатор прогресса

callback("write", writtenBytes>>20, writtenBytes, "") - вызывается многократно в процессе распаковки и передаёт общий
объём уже распакованных данных. Eсли вы заранее знаете сколько данных всего будет распаковано, это позволяет сделать
более точный индикатор прогресса

callback("filename", filesize>>20, filesize, filename) - сообщает о том, что сейчас начнётся распаковка файла filename
размером filesize байт

callback("overwrite?", size>>20, size, filename) - запрашивает разрешение на перезапись имеющегося на диске файла
файлом из архива размером size байт. Ответ (возвращённое из вызова callback значение):
    'y' - перезапись разрешена
    'n' - не перезаписывать
    'a' - больше не спрашивать и перезаписать все файлы
    's' - больше не спрашивать и не перезаписывать файлы
    'q' - завершить работу

callback("password?", pwdbuf_size, 0, pwd) - запрашивает пароль, который должен быть записан как UTF8Z строка в буфер
по адресу pwd размером pwdbuf_size байт. Этот callback может быть вызван многократно для проверки нескольких вариантов пароля,
если предыдущий предоставленный пароль не подошёл. Ответ:
    'y' - пароль возвращён в буфере
    'n' - пароля не будет или больше паролей нет
    'q' - завершить работу

callback("error", errcode, 0, errmsg) - вызывается при возникновении ошибки, передавая код ошибки
(см. FREEARC_ERRCODE_* в Common.h) и её текстовое описание

При возврате из колбеков помимо "overwrite?", "password?" и "error" значения <0 оно рассматривается как код ошибки,
произошедшей в колбеке, и распаковка досрочно прекращается. Значение, возвращённое из колбека "error", игнорируется.

Если callback==NULL, то на событие "overwrite?" возвращается ответ 's', на "password?" - ответ 'n', на остальные - ответ 0.



unarc.dll в отличие от unarc.exe не поддерживает команду 'v' и даёт несколько иное значение команде 'l': она возвращает
статистику архива, вызывая следующие колбеки:

callback("total_files", total_files, 0, "") - количество файлов в архиве
callback("origsize", origsize>>20, origsize, "") - суммарный исходный (несжатый) размер файлов в архиве
callback("compsize", compsize>>20, compsize, "") - суммарный сжатый размер файлов в архиве

Возвращаемые из callback значения при этом игнорируются.
