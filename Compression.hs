{-# OPTIONS_GHC -cpp #-}
----------------------------------------------------------------------------------------------------
---- Упаковка, распаковка и вычисление CRC.                                                     ----
---- Типы данных CompressionMethod, Compressor, UserCompressor - описание метода сжатия.        ----
---- Интерфейс с написанными на Си процедурами, выполняющими всю реальную работу.               ----
----------------------------------------------------------------------------------------------------
module Compression (module Compression, CompressionLib.decompressMem) where

import Control.Concurrent
import Control.Monad
import Data.Bits
import Data.Char
import Data.IORef
import Data.List
import Data.Maybe
import Data.Word
import Foreign.C.String
import Foreign.C.Types
import Foreign.Marshal.Alloc
import Foreign.Marshal.Pool
import Foreign.Ptr
import System.IO.Unsafe

#ifdef FREEARC_CELS
import qualified TABI
#endif
import qualified CompressionLib
import Utils
import Errors
import Files
import qualified ByteStream


-- |Метод сжатия или препроцессор и его параметры
type CompressionMethod  =  CompressionLib.Method

-- Методы "сжатия", поддерживаемые напрямую, а не через CompressionLib
aSTORING              = "storing"
aFAKE_COMPRESSION     = "fake"
aCRC_ONLY_COMPRESSION = "crc"

-- |Фейковые (нераспаковываемые) методы сжатия.
isFakeMethod             =  (==aFAKE_COMPRESSION) . method_name
-- |LZP метод сжатия.
isLZP_Method     method  =  method_name method == "lzp"
-- |Tornado метод сжатия.
isTornado_Method method  =  method_name method == "tor"
-- |DICT метод сжатия.
isDICT_Method    method  =  method_name method == "dict"
-- |TTA метод сжатия.
isTTA_Method     method  =  method_name method == "tta"
-- |MM метод сжатия.
isMM_Method      method  =  method_name method == "mm"
-- |JPG метод сжатия.
isJPG_Method     method  =  method_name method == "jpg"
-- |GRZip метод сжатия.
isGRZIP_Method   method  =  method_name method == "grzip"
-- |Метод, которому нужно подавать файлы по одному на солид-блок (bmf, tta и так далее)
isNonSolidMethod         =  CompressionLib.compressionIs "nosolid?"
-- |Очень быстрый метод упаковки (>10 mb/s на 1ГГц процессоре)
isVeryFastMethod         =  CompressionLib.compressionIs "VeryFast?"
-- |Быстрый метод распаковки
isFastDecMethod          =  not . any_function [(=="ppmd"), (=="ppmm"), (=="pmm"), isEXTERNAL_Method] . method_name
-- |Метод сжатия, выполняемый внешней программой
isEXTERNAL_Method        =  CompressionLib.compressionIs "external?"
-- |Метод сжатия, сохраняющий (при упаковке/распаковке, соответственно) все промежуточные данные на диске, что повзоляет освободить память перед началом работы следующих методов в цепочке
isMemoryBarrier_Compression    =  CompressionLib.compressionIs "MemoryBarrierCompression?"
isMemoryBarrier_Decompression  =  CompressionLib.compressionIs "MemoryBarrierDecompression?"
-- |Метод шифрования.
isEncryption             =  CompressionLib.compressionIs "encryption?"


-- |Последовательность алгоритмов сжатия, используемых для обработки данных
type Compressor = [CompressionMethod]

-- |Метод "storing" (-m0)
aNO_COMPRESSION = [aSTORING] :: Compressor

-- |Очень быстрое сжатие для уже сжатых файлов
aCOMPRESSED_METHOD = split_compressor "4$compressed"

-- |Это - фейковый компрессор, если в нём ровно один метод сжатия и он - фейковый
isFakeCompressor (method:xs)  =  isFakeMethod method  &&  null xs

-- |Это - fake компрессор, если в нём ровно один метод сжатия и он - "fake"
isReallyFakeCompressor (method:xs)  =  method_name method == aFAKE_COMPRESSION  &&  null xs

-- |Это - LZP компрессор, если в нём ровно один метод сжатия и он - LZP
isLZP_Compressor (method:xs)  =  isLZP_Method method  &&  null xs

-- |Это - очень быстрый упаковщик, если в нём ровно один, очень быстрый метод сжатия.
isVeryFastCompressor (method:xs)  =  isVeryFastMethod method  &&  null xs

-- |Это - быстрый распаковщик, если он включает только быстрые методы распаковки
isFastDecompressor = all isFastDecMethod


-- |Выбор компрессора в зависимости от типа обрабатываемых данных.
-- Первый элемент списка безымянен и описывает компрессор, используемый
-- по умолчанию (для файлов всех прочих типов, не описанных в списке явно)
type UserCompressor = [(String,Compressor)]  -- список ассоциаций типа "$text->m3t, $exe->m3x, $compressed->m0"

getCompressors :: UserCompressor -> [Compressor]
getCompressors = map snd

getMainCompressor :: UserCompressor -> Compressor
getMainCompressor = snd.head

-- |Это - метод Storing, если в нём только один компрессор aNO_COMPRESSION для файлов всех типов
isStoring ((_,compressor):xs)  =  compressor==aNO_COMPRESSION  &&  null xs

-- |Это - fake compression, если в нём только один фейковый компрессор для файлов всех типов
isFakeCompression ((_,compressor):xs)  =  isFakeCompressor compressor  &&  null xs

-- |Это - LZP compression, если в нём только один LZP компрессор для файлов всех типов
isLZP_Compression ((_,compressor):xs)  =  isLZP_Compressor compressor  &&  null xs

-- |Это очень быстрая упаковка, если в ней используются только очень быстрые упаковщики для файлов всех типов
isVeryFastCompression = all (isVeryFastCompressor.snd)

-- |Это быстрая распаковка, если в ней используются только быстрые распаковщики для файлов всех типов
isFastDecompression = all (isFastDecompressor.snd)

-- |Найти компрессор, наиболее подходящий для данных типа `ftype`.
-- Если компрессор для файлов этого типа не описан в списке - возвратить компрессор
-- по умолчанию, записанный в первый элемент списка
findCompressor ftype list  =  lookup ftype list  `defaultVal`  snd (head list)

-- |Для записи в оглавление архива информации об использованных алгоритмах сжатия.
instance ByteStream.BufferData Compressor where
  write buf x  =  ByteStream.write buf (join_compressor x)
  read  buf    =  ByteStream.read  buf  >>==  split_compressor


----------------------------------------------------------------------------------------------------
----- Операции над алгоритмами сжатия                                                          -----
----------------------------------------------------------------------------------------------------

class Compression a where
  getCompressionMem              :: a -> Integer
  getDecompressionMem            :: a -> Integer
  getMinCompressionMem           :: a -> Integer
  getMinDecompressionMem         :: a -> Integer
  getBlockSize                   :: a -> MemSize
  getDictionary                  :: a -> MemSize
  setDictionary                  :: MemSize -> a -> a
  limitCompressionMem            :: MemSize -> a -> a
  limitDecompressionMem          :: MemSize -> a -> a
  limitMinDecompressionMem       :: MemSize -> a -> a
  limitDictionary                :: MemSize -> a -> a

instance Compression CompressionMethod where
  getCompressionMem              =i.CompressionLib.getCompressionMem
  getDecompressionMem            =i.CompressionLib.getDecompressionMem
  getMinCompressionMem           =i.CompressionLib.getMinCompressionMem
  getMinDecompressionMem         =i.CompressionLib.getMinDecompressionMem
  getBlockSize                   =  CompressionLib.getBlockSize
  getDictionary                  =  CompressionLib.getDictionary
  setDictionary                  =  CompressionLib.setDictionary
  limitCompressionMem            =  CompressionLib.limitCompressionMem
  limitDecompressionMem          =  CompressionLib.limitDecompressionMem
  limitMinDecompressionMem       =  CompressionLib.limitMinDecompressionMem
  limitDictionary                =  CompressionLib.limitDictionary

instance Compression Compressor where
  getCompressionMem              =  calcMem getCompressionMem   isMemoryBarrier_Compression
  getDecompressionMem            =  calcMem getDecompressionMem isMemoryBarrier_Decompression
  getMinCompressionMem           =  maximum . map getMinCompressionMem
  getMinDecompressionMem         =  maximum . map getMinDecompressionMem
  getBlockSize                   =  maximum . map getBlockSize
  getDictionary                  =  maximum . map getDictionary
  setDictionary                  =  mapLast . setDictionary
  -- |Уменьшает потребности в памяти каждого алгоритма в цепочке до mem и затем вставляет между ними вызовы tempfile там, где необходимо
  limitCompressionMem      mem   =  map (limitCompressionMem   mem)  >>>  insertTempfile getCompressionMem   isMemoryBarrier_Compression   mem
  limitDecompressionMem    mem   =  map (limitDecompressionMem mem)  >>>  insertTempfile getDecompressionMem isMemoryBarrier_Decompression mem
  -- |Ограничивает алгоритм так, чтобы его можно было распаковать в заданном объёме памяти
  limitMinDecompressionMem mem   =  map (limitMinDecompressionMem mem)
  limitDictionary                =  compressionLimitDictionary

instance Compression UserCompressor where
  -- Определить максимальное потребление памяти / размер блока в заданном UserCompressor
  getCompressionMem              =  maximum . map (getCompressionMem      . snd)
  getDecompressionMem            =  maximum . map (getDecompressionMem    . snd)
  getMinCompressionMem           =  maximum . map (getMinCompressionMem   . snd)
  getMinDecompressionMem         =  maximum . map (getMinDecompressionMem . snd)
  getBlockSize                   =  maximum . map (getBlockSize           . snd)
  getDictionary                  =  maximum . map (getDictionary          . snd)
  -- Установить словарь / Ограничить используемую при сжатии/распаковке память
  -- сразу для всех методов, входящих в UserCompressor
  setDictionary                  =  mapSnds . setDictionary
  limitCompressionMem            =  mapSnds . limitCompressionMem
  limitDecompressionMem          =  mapSnds . limitDecompressionMem
  limitMinDecompressionMem       =  mapSnds . limitMinDecompressionMem
  limitDictionary                =  mapSnds . limitDictionary


-- |Ограничить словари для цепочки алгоритмов, прекратив это делать после первого алгоритма,
-- который может существенно раздуть данные (типа precomp). Среди внутренних алгоритмов
-- таких нет, но мы держим под подозрением все внешние :)
compressionLimitDictionary mem (x:xs) =  new_x : (not(isEXTERNAL_Method new_x)  &&&  compressionLimitDictionary mem) xs
                                             where new_x = limitDictionary mem x
compressionLimitDictionary mem []     =  []


-- |Вставляет вызовы tempfile между алгоритмами сжатия, разбивая их на "кластера",
-- умещающиеся в memory_limit+5% (при этом "маленькие" алгоритмы не должны начинать новых кластеров,
-- а external compressors обнуляют потребление памяти).
insertTempfile getMem isMemoryBarrier memory_limit | memory_limit==CompressionLib.aUNLIMITED_MEMORY  =  id
                                                   | otherwise                                       =  go (0::Double)
  where go _   []                                    =  []
        go mem (x:xs) | isMemoryBarrier x            =               x : go 0            xs
                      | mem==0                       =               x : go newMem       xs    -- не вставлять tempfile в начале цепочки или сразу за MemoryBarrier методом
                      | mem+newMem < memlimit*1.05   =               x : go (mem+newMem) xs
                      | otherwise                    =  "tempfile" : x : go newMem       xs

           where newMem   = realToFrac (getMem x)
                 memlimit = realToFrac memory_limit

-- |Посчитать потребности в памяти цепочки алгоритмов сжатия с учётом их разбиения на кластеры по compressionIs "external?"
calcMem getMem isMemoryBarrier  =  maximum . map (sum.map(i.getMem)) . splitOn isMemoryBarrier

-- |Удаляет все упоминания о "tempfile" из записи алгоритма сжатия.
compressionDeleteTempCompressors = filter (/="tempfile")


----------------------------------------------------------------------------------------------------
----- (De)compression of data stream                                                           -----
----------------------------------------------------------------------------------------------------

-- |Процедуры упаковки для различных алгоритмов сжатия.
freearcCompress   num method | isFakeMethod method =  eat_data
freearcCompress   num method                       =  CompressionLib.compress method

-- |Процедуры распаковки для различных алгоритмов сжатия.
freearcDecompress num  =  CompressionLib.decompress

-- |Читаем всё, не пишем ничего, а CRC считается в другом месте ;)
eat_data callback = do
  allocaBytes aBUFFER_SIZE $ \buf -> do  -- используем `alloca`, чтобы автоматически освободить выделенный буфер при выходе
    let go = do
#ifdef FREEARC_CELS
          len <- TABI.call (\a->fromIntegral `fmap` callback a) [TABI.Pair "request" "read", TABI.Pair "buf" buf, TABI.Pair "size" (aBUFFER_SIZE::MemSize)]
#else
          len <- callback "read" buf aBUFFER_SIZE
#endif
          if (len>0)
            then go
            else return len   -- Возвратим 0, если данные кончились, и отрицательное число, если произошла ошибка/больше данных не нужно
    go  -- возвратить результат


----------------------------------------------------------------------------------------------------
----- CRC calculation ------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------

-- |CRC файла
type CRC  = CUInt
aINIT_CRC = 0xffffffff  :: CRC
updateCRC addr len  =  c_UpdateCRC addr (i len)
finishCRC = xor aINIT_CRC

-- |Посчитать CRC данных в буфере
calcCRC addr len  =  updateCRC addr len aINIT_CRC  >>==  finishCRC

-- |Посчитать CRC не-unicode строки (символы с кодами 0..255)
crc32 str  =  unsafePerformIO$ withCStringLen str (uncurry calcCRC)

-- |Fast C routine for CRC-32 calculation
foreign import ccall safe "Environment.h UpdateCRC"
   c_UpdateCRC :: Ptr CChar -> CUInt -> CRC -> IO CRC


-------------------------------------------------------------------------------------------------------------
-- Encode/decode compression method for parsing options/printing info about selected compression method -----
-------------------------------------------------------------------------------------------------------------

-- |Parse command-line option that represents compression method.
-- Декодировать запись метода сжатия в виде текстовой строки, превратив его в список ассоциаций
-- "тип файла -> метод сжатия". Первый элемент этого списка описывает метод сжатия по умолчанию
decode_method cpus configuredMethodSubsts str =
    str                       -- "3/$obj=2b/$iso=ecm+3b"
    .$ select_full_by cpus    -- переключение методов сжатия в зависимости от числа ядер/процессоров
    .$ subst list             -- "3b/3t/$obj=2b/$iso=ecm+3b"
    .$ split_to_methods       -- [("","exe+3b"), ("$obj","3b"), ("$text","3t"), ("$obj","2b"), ("$iso","ecm+3b")]
    .$ keepOnlyLastOn fst     -- [("","exe+3b"), ("$text","3t"), ("$obj","2b"), ("$iso","ecm+3b")]
    .$ mapSnds (select_full_by cpus)
    .$ mapSnds (subst2 list)  -- [("",["exe","lzma"]), ("$text",["ppmd"]), ("$obj",["lzma"]), ("$iso",["ecm","lzma"])]
    .$ filter (not.null.snd)  -- "-m$bmp=" означает запретить использование специального алгоритма для группы $bmp

    where list = prepareSubsts (concatMap reorder [configuredMethodSubsts, builtinMethodSubsts])   -- сначала пользовательские замены, затем встроенные, чтобы дать первым приоритет
                 .$ mapSnds (select_full_by cpus)
          reorder list = a++b  where (a,b) = partition (notElem '#') list                          -- внутри этих групп: сначала строчки, не содержащие #, затем с # (сначала конкретные, затем общие замены)

-- |Аналогично select_by, но позволяет глобальную замену без внешних скобок
select_full_by cpus s  =  select_by cpus ("("++s++")")

-- |Выбрать из записи a|b|c метод сжатия, соответствующий количеству процессоров в системе
select_by cpus   =  parse ""  where
  -- Обработка множественных и вложенных скобок типа (a|b)(c|d(e|f))
  parse acc rest = case rest of
            '(':xs -> parse acc (parse "" xs)
            ')':xs -> multi (reverse acc) ++ xs
            ""     -> reverse acc
            x:xs   -> parse (x:acc) xs
  -- Выбор одной из альтернатив по количеству cpu: (A|B||D) означает метод A для cpu=1, B для cpu=2 или 3, D для cpu>=4
  multi s  =  (repeater ""$ split '|' s) !! (cpus-1)
  -- Повторяет элементы в списке для multi: (A|B||D) -> (A|B|B|D|D|D...)
  repeater last ss  =  case ss of
                ("":xs) -> last : repeater last xs
                (x :xs) -> x    : repeater x    xs
                []      -> repeat last

-- Замена по списку для метода сжатия (обобщённого обозначения для файлов всех типов)
subst list method  =  joinWith "/" (main_methods:group_methods++user_methods)
  where -- Из записи типа -m3/$obj=2b выделяем для расшифровки только первую часть, до слеша
        main:user_methods = split '/' method
        -- Расшифровка основных методов сжатия, типа 3x = 3xb/3xt
        main_methods = case (lookup main list) of
            Just x  -> subst list x   -- При успехе повторяем рекурсивно
            Nothing -> main           -- Больше подстановок нет
        -- Найдём в списке подстановок дополнительные методы сжатия для отдельных групп, типа 3x$iso = ecm+exe+3xb
        group_methods = list .$ keepOnlyFirstOn fst                      -- удалим повторные определения (не очень эффективно делать это именно здесь, зато по месту использования)
                             .$ mapMaybe (startFrom main . join2 "=")    -- оставим только определения, начинающиеся с 3x, удалив это 3x
                             .$ filter (("$"==).take 1)                  -- а из них - только начинающиеся с $

-- Замена по списку для алгоритма сжатия (посл-ти компрессоров для конкретного типа файлов)
subst2 list ""     =  []
subst2 list method =  concatMap f (split_compressor method)
    where f method = let (head,params)  =  break (==':') method
                     in case (lookup head list) of
                          Just new_head -> subst2 list (new_head++params)
                          Nothing       -> [decode_one_method method]

-- |Декодировать явно описанный метод сжатия.
decode_one_method method | isFakeMethod method = method
                         | otherwise           = CompressionLib.canonizeCompressionMethod method

-- Превращает длинную строку, описывающую методы сжатия для разных типов файлов,
-- в массив ассоциаций (тип файла, метод сжатия)
split_to_methods method = case (split '/' method) of
    [_]                 ->  [("",method)]   -- один метод для файлов всех типов
    x : xs@ (('$':_):_) ->  ("",x) : map (split2 '=') xs   -- m1/$type=m2...
    b : t : xs          ->  [("","exe+"++b), ("$obj",b), ("$text",t)] ++ map (split2 '=') xs   -- m1/m2/$type=m3...

-- Подготовить список замен к использованию в lookup
prepareSubsts x = x
    -- Удалить пустые строки, пробелы и комментарии
    .$ map (filter (not.isSpace) . fst . split2 ';') .$ filter (not.null)
    -- Заменить каждую строку с символом # на 9 строк, где # пробегает значения от 1 до 9
    .$ concatMap (\s -> if s `contains` '#'  then map (\d->replace '#' d s) ['1'..'9']  else [s])
    -- Преобразовать список строк вида "a=b" в список для lookup
    .$ map (split2 '=')

-- Встроенные описания методов сжатия в формате, аналогичном используемому в arc.ini
builtinMethodSubsts = [
      ";High-level method definitions"
    , "x  = 9            ;highest compression mode using only internal algorithms"
    , "ax = 9p           ;highest compression mode involving external compressors"
    , "0  = storing"
    , "1  = 1b"
    , "1x = 1"
    , "#  = #rep+exe+#xb / $obj=#b / $text=#t"
    , "#x = #xb/#xt"
    , ""
    , ";Text files compression with slow decompression"
    , "1t  = 1b"
    , "2t  = grzip:m4:8m:32:h15                                             | ex2t"
    , "3t  = dict:p: 64m:85% + lzp: 64m: 24:h20        :92% + grzip:m3:8m:l | ex3t"
    , "4t  = dict:p: 64m:80% + lzp: 64m: 65:d1m:s16:h20:90% + ppmd:8:96m    | ex4t"
    , "5t  = dict:p: 64m:80% + lzp: 80m:105:d1m:s32:h22:92% + ppmd:12:192m  | ex5t"
    , "#t  = dict:p:128m:80% + lzp:160m:145:d1m:s32:h23:92% + ppmd:16:384m"
    , ""
    , ";Binary files compression with slow and/or memory-expensive decompression"
    , "#b  = #rep+#bx"
    , "1rep  = rep:  96m:256:c256"
    , "2rep  = rep:  96m:256:c256"
    , "3rep  = rep:  96m"
    , "4rep  = rep:  96m"
    , "5rep  = rep:  96m"
    , "6rep  = rep: 256m"
    , "7rep  = rep: 512m"
    , "8rep  = rep:1024m"
    , "9rep  = rep:2040m"
    , ""
    , ";Text files compression with fast decompression"
    , "1xt = 1xb"
    , "2xt = 2xb"
    , "3xt = dict:  64m:80% + tor:7:96m:h64m"
    , "4xt = dict:  64m:75% + 4binary"
    , "#xt = dict: 128m:75% + #binary"
    , ""
    , ";Binary files compression with fast decompression"
    , "1xb = 1binary"
    , "2xb = 2binary"
    , "#xb = delta + #binary"
    , ""
    , ";Binary files compression with fast decompression"
    , "1binary = tor:4                       | ex1binary"
    , "2binary = tor:6                       | ex2binary"
    , "3binary = lzma: 96m:fast  :32:mc4     | ex3binary"
    , "4binary = lzma: 96m:normal:16:mc8   | | ex4binary"
    , "5binary = lzma: 96m:normal:32:mc32  | | ex5binary"
    , "6binary = lzma: 32m:max"
    , "7binary = lzma: 64m:max"
    , "8binary = lzma:128m:max"
    , "9binary = lzma:254m:max"
    , ""
    , ";One more family of methods providing fast but memory-hungry decompression: -m1d, -m2d..."
    , "#d = #rep+exe+#xb / $obj=#b / $text=dict+#b / $compressed = #$compressed / $wav = #x$wav / $bmp = #x$bmp"
    , ""
    , ";Synonyms"
    , "bcj = exe"
    , "#bx = #xb"
    , "#tx = #xt"
    , "x#  = #x"    -- принимаем опции типа "-mx7" для мимикрии под 7-zip
    , "copy = storing"
    , "exe2 = dispack"
    , "dispack = dispack070"
    , ""
    , ""
    , ";Sound wave files are best compressed with TTA"
    , "wav     = tta      ;best compression"
    , "wavfast = tta:m1   ;faster compression and decompression"
    , "1$wav  = ;;; wavfast | bmpfastest"
    , "2$wav  = wavfast"
    , "#$wav  = wav"
    , "#x$wav = wavfast"
    , ""
    , ";Bitmap graphic files are best compressed with GRZip"
    , "bmp        = mm    + grzip:m1:l2048:a  ;best compression"
    , "bmpfast    = mm    + grzip:m4:l:a      ;faster compression"
    , "bmpfastest = mm:d1 + 1binary:t0        ;fastest one"
    , "1$bmp  = ;;; bmpfastest"
    , "2$bmp  = bmpfastest | bmpfast"
    , "3$bmp  = bmpfast    | bmp"
    , "#$bmp  = bmp"
    , "1x$bmp = bmpfastest"
    , "2x$bmp = bmpfastest"
    , "#x$bmp = mm+#binary"
    , ""
    , ";Quick & dirty compression for already compressed data"
    , "1$compressed   = storing | 1rep"
    , "2$compressed   = 2rep + 1binary"
    , "3$compressed   = 3rep + 1binary"
    , "4$compressed   = 4rep + etor:c3"
    , "#$compressed   = "
    , ""
    , "1x$compressed  = storing | 1rep"
    , "2x$compressed  = 2rep:8m + 1binary"
    , "3x$compressed  = 3rep:8m + 1binary"
    , "4x$compressed  = etor:8m:c3"
    , "#x$compressed  = "
    , ""
    , ";LZ4 support"
    , "xlz4   = 4x4:lz4"
    , "elz4   = (|x)lz4"
    , "lz4hc  = lz4:hc"
    , "xlz4hc = 4x4:lz4:hc"
    , "elz4hc = (|x)lz4hc"
    , ""
    , ""
    , ";Multi-threading compression modes"
    , "xtor  = 4x4:tor"
    , "xlzma = 4x4:lzma"
    , "xppmd = 4x4:b7mb:ppmd"
    , "etor  = (|x)tor"
    , "elzma = (|x)lzma"
    , "eppmd = (|x)ppmd"
    , ""
    , "ex1 = ex1b / $wav=mm:d1+ex1b:t0 / $bmp=mm:d1+ex1b:t0 / $compressed = #$compressed"
    , "ex# = #rep+exe+ex#b / $obj=#rep+ex#b / $text=ex#t / $wav = #$wav / $bmp = #$bmp / $compressed = #$compressed"
    , "#ex = ex#"
    , ""
    , "ex1b = ex1binary"
    , "ex2b = ex2binary"
    , "ex#b = delta + ex#binary"
    , ""
    , "ex1binary = xtor:3:8mb"
    , "ex2binary = xtor:5"
    , "ex3binary = xlzma:96mb:fast  :32:mc4"
    , "ex4binary = xlzma:96mb:normal:16:mc8"
    , "ex5binary = xlzma:96mb:normal:32:mc32"
    , "ex6binary = 4x4:i0:lzma: 8mb:max"
    , "ex7binary = 4x4:i0:lzma:16mb:max"
    , "ex8binary = 4x4:i0:lzma:32mb:max"
    , "ex9binary = 4x4:i0:lzma:64mb:max"
    , ""
    , "ex1t = ex1b"
    , "ex2t = grzip:m4"
    , "ex3t = grzip:m2"
    , "ex4t = grzip:m1"        -- dict:p: 64m:80% + lzp:  8m: 45:d1m:s16:h15:92% + xppmd:6:48m
    , "ex5t = dict:p: 64m:80% + lzp: 64m: 65:d1m:s32:h22:90% + xppmd:8:96m"
    , "ex6t = dict:p: 64m:80% + lzp: 80m:105:d1m:s32:h22:92% + xppmd:12:192m"
    , "ex#t = dict:p:128m:80% + lzp:160m:145:d1m:s32:h23:92% + xppmd:16:384m"
    ]

-- |Мультимедийный тип файлов?
isMMType x  =  x `elem` words "$wav $bmp"

-- |В некотором смысле обратная операция - угадывание типа файла по его компрессору
typeByCompressor c  =  case (map method_name c) of
  xs | xs `contains` "tta"        -> "$wav"
     | xs `contains` "mm"         -> "$bmp"
     | xs `contains` "grzip"      -> "$text"
     | xs `contains` "ppmd"       -> "$text"
     | xs `contains` "pmm"        -> "$text"
     | xs `contains` "dict"       -> "$text"
     | xs == aNO_COMPRESSION      -> "$compressed"
     | xs == ["rep","tor"]        -> "$compressed"
     | xs `contains` "ecm"        -> "$iso"
     | xs `contains` "precomp"    -> "$precomp"
     | xs == ["precomp","rep"]    -> "$jpgsolid"
     | xs `contains` "jpg"        -> "$jpg"
     | xs `contains` "exe"        -> "$binary"
     | xs `contains` "lzma"       -> "$obj"
     | xs `contains` "tor"        -> "$obj"
     | otherwise                  -> "default"

-- |Список всех типов файлов, обнаруживаемых подобным образом
typesByCompressor = words "$wav $bmp $text $compressed $iso $precomp $jpgsolid $jpg $obj $binary $exe"


-- |Human-readable description of compression method
encode_method uc  =  joinWith ", " (map encode_one_method uc)
encode_one_method (group,compressor)  =  between group " => " (join_compressor compressor)
join_compressor   =  joinWith "+"

-- |Opposite to join_compressor (used to read compression method from archive file)
split_compressor  =  split '+'

-- |Обработать алгоритмы в компрессоре императивной операцией process
process_algorithms process compressor = do
    return (split_compressor compressor)
       >>=  mapM process
       >>== join_compressor

-- |Соеденить метод сжатия из его названия и параметров
join_method = joinWith ":"

-- |Разбить метод сжатия на заголовок и отдельные параметры
split_method = split ':'

-- |Имя метода сжатия.
method_name = head . split_method

-- |Строка, информирующая пользователя об используемом объёме памяти
showMem 0      = "0b"
showMem mem    = showM [(gb,"gb"),(mb,"mb"),(kb,"kb"),(b,"b"),error"showMem"] mem

showMemory 0   = "0 bytes"
showMemory mem = showM [(gb," gbytes"),(mb," mbytes"),(kb," kbytes"),(b," bytes"),error"showMemory"] mem

showM xs@( (val,str) : ~(nextval,_) : _) mem =
  if mem `mod` val==0 || mem `div` nextval>=4096
    then show((mem+val`div` 2) `div` val)++str
    else showM (tail xs) mem

-- |Округлить объём памяти вверх так, чтобы он приобрёл читабельность
roundMemUp mem | mem>=4096*kb = mem `roundUp` mb
               | otherwise    = mem `roundUp` kb

{-# NOINLINE builtinMethodSubsts #-}
{-# NOINLINE decode_method #-}
{-# NOINLINE showMem #-}
