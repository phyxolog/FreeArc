{-# OPTIONS_GHC -cpp #-}
---------------------------------------------------------------------------------------------------
---- Регистрация ошибок/предупреждений и печать сообщений о них. ----------------------------------
---------------------------------------------------------------------------------------------------
module Errors where

import Prelude hiding (catch)
import Control.Concurrent
import Control.OldException
import Control.Monad
import Data.Char
import Data.Maybe
import Data.IORef
import System.Exit
import System.IO
import System.IO.Unsafe
#if defined(FREEARC_WIN)
import GHC.ConsoleHandler
#else
import System.Posix.Signals
#endif

import CompressionLib   (compressionLib_cleanup)
import Utils
import Files
import Charsets

-- |Коды возврата программы
aEXIT_CODE_SUCCESS      = 0
aEXIT_CODE_WARNINGS     = 1
aEXIT_CODE_FATAL_ERROR  = 2
aEXIT_CODE_BAD_PASSWORD = 21
aEXIT_CODE_USER_BREAK   = 255

-- |Все возможные типы ошибок и предупреждений
data ErrorType  = GENERAL_ERROR                 [String]
                | CMDLINE_GENERAL               [String]
                | CMDLINE_SYNTAX                String
                | CMDLINE_INCOMPATIBLE_OPTIONS  String String
                | CMDLINE_NO_COMMAND            [String]
                | CMDLINE_NO_ARCSPEC            [String]
                | CMDLINE_NO_FILENAMES          [String]
                | UNKNOWN_CMD                   String [String]
                | CMDLINE_UNKNOWN_OPTION        String
                | CMDLINE_AMBIGUOUS_OPTION      String [String]
                | CMDLINE_BAD_OPTION_FORMAT     String
                | INVALID_OPTION_VALUE          String String [String]
                | CANT_READ_DIRECTORY           String
                | CANT_GET_FILEINFO             String
                | CANT_OPEN_FILE                String
                | UNSUPPORTED_METHOD            String
                | DATA_ERROR                    String
                | DATA_ERROR_ENCRYPTED          String
                | BAD_CRC                       String
                | BAD_CRC_ENCRYPTED             String
                | UNKNOWN_ERROR                 String
                | BAD_CFG_SECTION               String [String]
                | OP_TERMINATED
                | TERMINATED
                | NOFILES
                | SKIPPED_FAKE_FILES            Int
                | BROKEN_ARCHIVE                FilePath [String]
                | INTERNAL_ERROR                String
                | COMPRESSION_ERROR             [String]
                | BAD_PASSWORD                  FilePath FilePath
  deriving (Eq)


--foreign import "&errCounter" :: Ptr Int
{-
data SqliteException = SqliteException Int String
  deriving (Typeable)

catchSqlite :: IO a -> (SqliteException -> IO a) -> IO a
catchSqlite = catchDyn

throwSqlite :: SqliteException -> a
throwSqlite = throwDyn
-}

---------------------------------------------------------------------------------------------------
---- Обработка Ctrl-Break, Close и т.п. внешних событий -------------------------------------------
---------------------------------------------------------------------------------------------------

setCtrlBreakHandler action = do
  --myThread <- myThreadId
  -- При выходе или возникновении исключения восстановим предыдущий обработчик событий
#if defined(FREEARC_WIN)
  bracket (installHandler$ Catch onBreak) (installHandler) $  \oldHandler -> do
    action
#else
  let catchSignals a  =  installHandler sigINT (CatchOnce$ onBreak undefined) Nothing
  bracket (catchSignals (CatchOnce$ onBreak (error "onBreak"))) (catchSignals) $  \oldHandler -> do
    action
#endif

-- |Вызвать fail, если установлен флаг аварийного завершения программы
failOnTerminated = do
  whenM (val operationTerminated) $ do
    fail ""

-- |Обработка Ctrl-Break и нажатия на Cancel сводится к выполнению финализаторов и
-- установке спец. флага, который проверяется коллбэками, вызываемыми из Си
onBreak event = terminateOperation
terminateOperation = do
  isFM <- val fileManagerMode
  registerError$ iif isFM OP_TERMINATED TERMINATED

-- |Принудительно завершает выполнение программы с заданным exitCode и печатью сообщения msg
shutdown msg exitCode = do
  w <- val warnings
  -- Make cleanup unless this is a second call (after pause)
  unlessM (val programFinished) $ do
    programFinished =: True
    separator' =: ("","\n")
    log_separator' =: "\n"

    fin <- val finalizers
    for fin $ \(name,id,action) -> do
      ignoreErrors$ action
    compressionLib_cleanup

    unlessM (val fileManagerMode) $ do
      case w of
        0 -> when (exitCode==aEXIT_CODE_SUCCESS) $ condPrintLineLn "k" "All OK"
        _ -> condPrintLineLn "n"$ "There were "++show w++" warning(s)"
      ignoreErrors (msg &&& condPrintLineLn "n" msg)
      condPrintLineLn "e" ""
#if !defined(FREEARC_GUI)
    putStrLn ""
#endif

    ignoreErrors$ closeLogFile
    ignoreErrors$ hFlush stdout
    ignoreErrors$ hFlush stderr
    --killThread myThread

    -- Выключить компьютер если запрошено
    powerOffComputer `onM` val perform_shutdown

    -- Make a pause if necessary
    unlessM (val fileManagerMode) $ do
      when (exitCode/=aEXIT_CODE_USER_BREAK) $ do
        warningsBefore' <- val warningsBefore
        pause_option <- val pause_before_exit
        pause <- val pauseAction
        case pause_option of
          "on"          -> pause
          "on-warnings" -> pause `on_` w>warningsBefore' || exitCode/=aEXIT_CODE_SUCCESS
          "on-error"    -> pause `on_` exitCode/=aEXIT_CODE_SUCCESS
          _             -> doNothing0

  -- And finally - exit program!
  exit (exitCode  |||  (w &&& aEXIT_CODE_WARNINGS))
#if 0
  -- Более корректный способ завершения программы, к сожалению arc.exe с ним иногда виснет
  exitWith$ case () of
   _ | exitCode>0 -> ExitFailure exitCode
     | w>0        -> ExitFailure aEXIT_CODE_WARNINGS
     | otherwise  -> ExitSuccess
#endif
  return undefined

-- |Вызывается когда очередь команд становится пуста
onEmptyQueue  =  powerOffComputer `onM` val perform_shutdown

-- |"handle" с выполнением "onException" также при ^Break
handleCtrlBreak name onException action = do
  failOnTerminated
  id <- newId
  handle (\e -> do onException; throwIO e) $ do
    bracket_ (addFinalizer name id onException)
             (removeFinalizer id)
             (action)

-- |"bracket" с выполнением "close" также при ^Break
bracketCtrlBreak name init close action = do
  failOnTerminated
  id <- newId
  bracket (do x<-init; addFinalizer name id (close x); return x)
          (\x -> do removeFinalizer      id; close x)
          action

-- |bracketCtrlBreak, выполняющий fail при возврате Nothing из init
bracketCtrlBreakMaybe name init fail close action = do
  bracketCtrlBreak name (do x<-init; when (isNothing x) fail; return x)
                        (`whenJust_` close)
                        (`whenJust`  action)

-- |Выполнить close-действие по завершению action
ensureCtrlBreak name close action  =  bracketCtrlBreak name (return ()) (\_->close) (\_->action)

-- Добавить/удалить finalizer в список
addFinalizer name id action  =  finalizers .= ((name,id,action):)
removeFinalizer id           =  finalizers .= filter ((/=id).snd3)
newId                        =  do curId+=1; id<-val curId; return id

-- |Уникальный номер
curId :: IORef Int
curId = unsafePerformIO (ref 0)
{-# NOINLINE curId #-}

-- |Список действий, которые надо выполнить перед аварийным завершением программы
finalizers :: IORef [(String, Int, IO ())]
finalizers = unsafePerformIO (ref [])
{-# NOINLINE finalizers #-}

-- |ИД основного треда операции (только в режиме файл-менеджера)
parent_id :: IORef ThreadId
parent_id = unsafePerformIO (ref undefined)
{-# NOINLINE parent_id #-}

-- |Флаг, показывающий что мы находимся в режиме прерывания текущей операции
operationTerminated = unsafePerformIO (ref False)
{-# NOINLINE operationTerminated #-}

-- |Устанавливается после завершения выполнения всех команд, когда мы просто ждём закрытия окна программы
programFinished = unsafePerformIO (ref False)
{-# NOINLINE programFinished #-}

-- |Режим работы файл-менеджера: при этом registerError обрабатывается по-другому - мы дожидаемся завершения всех тредов упаковки и распаковки
fileManagerMode = unsafePerformIO (ref False)
{-# NOINLINE fileManagerMode #-}

-- |Делать ли паузу перед выходом из программы?
pause_before_exit = unsafePerformIO (ref "")
{-# NOINLINE pause_before_exit #-}

-- |UI-операция, вызываемая для задержки выхода из программы
pauseAction = unsafePerformIO (ref$ return ()) :: IORef (IO())
{-# NOINLINE pauseAction #-}

-- |Выключить компьютер по окончанию работы?
perform_shutdown = unsafePerformIO (ref False)
{-# NOINLINE perform_shutdown #-}


---------------------------------------------------------------------------------------------------
---- Тексты сообщений о различных типах ошибок. Подходящий ресурс для интернализации --------------
---------------------------------------------------------------------------------------------------

errormsg (GENERAL_ERROR msgs) =
  i18fmt msgs

errormsg (BROKEN_ARCHIVE arcname msgs) = do
  msg <- i18fmt msgs
  i18fmt ["0341 %1 isn't archive or this archive is corrupt: %2. Please recover it using 'r' command or use -tp- option to ignore Recovery Record", arcname, msg]

errormsg (INTERNAL_ERROR msg) =
  return$ aFreeArc++" internal error: "++msg

errormsg (COMPRESSION_ERROR msgs) =
  i18fmt msgs

errormsg (CMDLINE_GENERAL msgs) =
  i18fmt msgs

errormsg (CMDLINE_SYNTAX syntax) =
  i18fmt ["0318 command syntax is \"%1\"", syntax]

errormsg (CMDLINE_INCOMPATIBLE_OPTIONS option1 option2) =
  i18fmt ["0319 options %1 and %2 can't be used together", option1, option2]

errormsg (UNKNOWN_CMD cmd known_cmds) =
  i18fmt ["0320 unknown command \"%1\". Supported commands are: %2", cmd, joinWith ", " known_cmds]

errormsg (CMDLINE_UNKNOWN_OPTION option) =
  i18fmt ["0321 unknown option \"%1\"", option]

errormsg (CMDLINE_AMBIGUOUS_OPTION option variants) = do
  or <- i18n"0323 or"
  i18fmt ["0322 ambiguous option \"%1\" - is that %2?", option, enumerate or variants]

errormsg (CMDLINE_BAD_OPTION_FORMAT option) =
  i18fmt ["0325 option \"%1\" have illegal format", option]

errormsg (INVALID_OPTION_VALUE fullname shortname valid_values) = do
  or <- i18n"0323 or"
  let spelling | shortname>"" = (('-':shortname)++)
               | otherwise    = (("--"++fullname++"=")++)
  i18fmt ["0326 %1 option must be one of: %2", fullname, enumerate or (map spelling valid_values)]

errormsg (CMDLINE_NO_COMMAND args) =
  i18fmt ["0327 no command name in command: %1", unwords args]

errormsg (CMDLINE_NO_ARCSPEC args) =
  i18fmt ["0328 no archive name in command: %1", unwords args]

errormsg (CMDLINE_NO_FILENAMES args) =
  i18fmt ["0329 no filenames in command: %1", unwords args]

errormsg (CANT_READ_DIRECTORY dir) =
  i18fmt ["0330 can't read directory \"%1\"", dir]

errormsg (CANT_GET_FILEINFO filename) =
  i18fmt ["0331 can't get info about file \"%1\"", filename]

errormsg (CANT_OPEN_FILE filename) =
  i18fmt ["0332 can't open file \"%1\"", filename]

errormsg (UNSUPPORTED_METHOD filename) =
  i18fmt ["0472 Unsupported compression method for \"%1\".", filename]

errormsg (DATA_ERROR filename) =
  i18fmt ["0473 Data error in \"%1\". File is broken.", filename]

errormsg (DATA_ERROR_ENCRYPTED filename) =
  i18fmt ["0474 Data error in encrypted file \"%1\". Wrong password?", filename]

errormsg (BAD_CRC filename) =
  i18fmt ["0475 CRC failed in \"%1\". File is broken.", filename]

errormsg (BAD_CRC_ENCRYPTED filename) =
  i18fmt ["0476 CRC failed in encrypted file \"%1\". Wrong password?", filename]

errormsg (UNKNOWN_ERROR filename) =
  i18fmt ["0477 Unknown error", filename]

errormsg (BAD_CFG_SECTION cfgfile section) =
  i18fmt ["0334 bad section %1 in %2", head section, cfgfile]

errormsg (OP_TERMINATED) =
  i18fmt ["0455 Operation terminated by user!"]

errormsg (TERMINATED) =
  i18fmt ["0456 Program terminated by user!"]

errormsg (NOFILES) =
  i18fmt ["0337 no files, erasing empty archive"]

errormsg (SKIPPED_FAKE_FILES n) =
  i18fmt ["0338 skipped %1 fake files", show n]

errormsg (BAD_PASSWORD archive "") =
  i18fmt ["0339 bad password for archive %1", archive]

errormsg (BAD_PASSWORD archive file) =
  i18fmt ["0340 bad password for %1 in archive %2", file, archive]


-- |Перечислить список значений
enumerate s list  =  joinWith2 ", " (" "++s++" ") (map quote list)

{-# NOINLINE errormsg #-}


----------------------------------------------------------------------------------------------------
---- Коды выхода для различных ошибок --------------------------------------------------------------
----------------------------------------------------------------------------------------------------

errcode TERMINATED     = aEXIT_CODE_USER_BREAK
errcode BAD_PASSWORD{} = aEXIT_CODE_BAD_PASSWORD
errcode _              = aEXIT_CODE_FATAL_ERROR


----------------------------------------------------------------------------------------------------
---- Ввод/вывод на экран в кодировке, заданной опцией -sct -----------------------------------------
----------------------------------------------------------------------------------------------------

#if !defined(FREEARC_GUI) && !defined(FREEARC_DLL)
myGetLine     = getLine >>= terminal2str
myPutStr      = putStr   =<<. str2terminal
myPutStrLn    = putStrLn =<<. str2terminal
myFlushStdout = hFlush stdout
#else
myPutStr      = doNothing
myPutStrLn    = doNothing
myFlushStdout = doNothing0
#endif


----------------------------------------------------------------------------------------------------
---- Работа с логфайлом и управление объёмом вывода на экран в соответствии с опцией --display -----
----------------------------------------------------------------------------------------------------

-- Напечатать заданную строку, отделив её при необходимости от предыдущей команды/обработанного архива
-- Кроме того, первая буква печатаемой строки переводится в нижний регистр,
-- если она печатается непосредственно после заголовка программы
printLine = printLineC ""
printLineC c str = do
  (oldc,separator) <- val separator'
  let makeLower (x:y:zs) | isLower y  =  toLower x:y:zs
      makeLower xs                    =  xs
  let handle "w" = stderr
      handle _   = stdout
#if !defined(FREEARC_GUI) && !defined(FREEARC_DLL)
  hPutStr (handle oldc) =<< str2terminal separator
  hPutStr (handle c)    =<< str2terminal ((oldc=="h" &&& makeLower) str)
  hFlush  (handle c)
#endif
  separator' =: (c,"")

-- |Напечатать строку с разделителем строк после неё
printLineLn str = do
  printLine str
  printLineNeedSeparator "\n"

-- Отделить последующий вывод заданной строкой. Не выводим эту строку сразу,
-- поскольку никакого последующего вывода может и не быть :)))
printLineNeedSeparator str = do
  separator' =: ("",str)

-- |Напечатать строку с разделителем строк после неё
condPrintLineLn c line = do
  condPrintLine c line
  condPrintLineNeedSeparator c "\n"

-- Записать строку в логфайл.
-- Вывести её на экран при условии, что её вывод не запрещён опцией --display
condPrintLine c line = do
  if c=="G" then val loggingHandlers >>= mapM_ ($line) else do
  display_option <- val display_option'
  when (c `notElem` words "$ !"   ||   (display_option `contains` '#')) $ do
      printLog line
  when (display_option `contains_one_of` c) $ do
      printLineC c line

-- Отделить последующий вывод заданной строкой при условии разрешения вывода класса c
condPrintLineNeedSeparator c str = do
  display_option <- val display_option'
  when (c `notElem` words "$ !"   ||   (display_option `contains` '#')) $ do
      log_separator' =: str
  when (c=="" || (display_option `contains_one_of` c)) $ do
      separator' =: (c,str)

-- Открыть логфайл
openLogFile logfilename = do
  closeLogFile  -- закрыть предыдущий, если был
  logfile <- case logfilename of
                 ""  -> return Nothing
                 log -> (do buildPathTo log
                            fileAppendText log >>== Just)
                        `catch` (\e -> do registerWarning (CANT_OPEN_FILE log)
                                          return Nothing)
  logfile' =: logfile

-- Вывести строку в логфайл
printLog line = do
  separator <- val log_separator'
  whenJustM_ (val logfile') $ \log -> do
      fileWrite log =<< str2logfile (separator ++ line); fileFlush log
      log_separator' =: ""

-- Закрыть логфайл
closeLogFile = do
  whenJustM_ (val logfile') fileClose
  logfile' =: Nothing

-- Переменная, хранящая Handle логфайла
logfile'        = unsafePerformIO$ newIORef Nothing
-- Переменные, используемые для украшения печати
separator'      = unsafePerformIO$ newIORef ("","") :: IORef (String,String)
log_separator'  = unsafePerformIO$ newIORef "\n"    :: IORef String
display_option' = unsafePerformIO$ newIORef ""      :: IORef String
-- Операции вывода сообщений в лог
loggingHandlers = unsafePerformIO$ newIORef [] :: IORef [String -> IO ()]

{-# NOINLINE printLine #-}
{-# NOINLINE printLineNeedSeparator #-}
{-# NOINLINE condPrintLine #-}
{-# NOINLINE condPrintLineNeedSeparator #-}
{-# NOINLINE separator' #-}
{-# NOINLINE log_separator' #-}
{-# NOINLINE display_option' #-}

----------------------------------------------------------------------------------------------------
---- Печать сообщений об ошибках и предупреждений
----------------------------------------------------------------------------------------------------

-- |Запись сообщения об ошибке в логфайл и аварийное завершение программы с этим сообщением
registerError err = do
  unless (err `elem` [TERMINATED,OP_TERMINATED]) $ do
    val errcodeHandler >>= ($err)
  msg <- errormsg err
  msg <- if err `elem` [TERMINATED,OP_TERMINATED]
           then return msg
           else i18fmt ["0316 ERROR: %1", msg]
  val errorHandlers >>= mapM_ ($msg)
  -- Если мы не в режиме файл-менеджера - совершаем аварийный выход из программы
  unlessM (val fileManagerMode) $ do
    shutdown msg (errcode err)
  -- Иначе ждём завершения всех тредов компрессии
  operationTerminated =: True
  killThread =<< val parent_id
  fail ""

-- |Запись предупреждения в логфайл и вывод его на экран
registerWarning warn = do
  warnings += 1
  msg <- errormsg warn
  msg <- i18fmt ["0317 WARNING: %1", msg]
  val warningHandlers >>= mapM_ ($msg)
  condPrintLineLn "w" msg

-- |Выполнить операцию и возвратить количество возникших при этом warning'ов
count_warnings action = do
  w0 <- val warnings
  action
  w  <- val warnings
  return (w-w0)

-- |Счётчик ошибок, возникших в ходе работы программы
warnings = unsafePerformIO$ newIORef 0 :: IORef Int
-- |Количество предупреждений перед последним показом диалога прогресса
warningsBefore = unsafePerformIO$ newIORef 0 :: IORef Int

-- В зависимости от режима зарегистрировать ошибку или предупреждение
registerThreadError err = do
  isFM <- val fileManagerMode
  (iif isFM registerWarning registerError) err

-- Операции, выполняемые при появлении ошибки/предупреждения (регистрируются в других частях программы)
errcodeHandler  = unsafePerformIO$ newIORef doNothing :: IORef (ErrorType -> IO ())
errorHandlers   = unsafePerformIO$ newIORef [] :: IORef [String -> IO ()]
warningHandlers = unsafePerformIO$ newIORef [] :: IORef [String -> IO ()]

{-# NOINLINE registerError #-}
{-# NOINLINE registerWarning #-}
{-# NOINLINE warnings #-}
{-# NOINLINE warningsBefore #-}
{-# NOINLINE errorHandlers #-}
{-# NOINLINE warningHandlers #-}

----------------------------------------------------------------------------------------------------
---- Работа с файлами
----------------------------------------------------------------------------------------------------

-- |Возвратить Nothing и напечатать сообщение об ошибке, если файл не удалось открыть
tryOpen filename = catchJust ioErrors
                     (fileOpen filename >>== Just)
                     (\e -> do registerWarning$ CANT_OPEN_FILE filename; return Nothing)

-- |Скопировать файл
fileCopy srcname dstname = do
  bracketCtrlBreak "fileClose1:fileCopy" (fileOpen srcname) (fileClose) $ \srcfile -> do
    handleCtrlBreak "fileRemove1:fileCopy" (ignoreErrors$ fileRemove dstname) $ do
      bracketCtrlBreak "fileClose2:fileCopy" (fileCreate dstname) (fileClose) $ \dstfile -> do
        size <- fileGetSize srcfile
        fileCopyBytes srcfile size dstfile


----------------------------------------------------------------------------------------------------
----- External functions ---------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------

-- |Stop program execution
foreign import ccall unsafe "stdlib.h exit"
  exit :: Int -> IO ()

-- |Reboot computer (
foreign import ccall unsafe "PowerOffComputer"
  powerOffComputer :: IO ()

