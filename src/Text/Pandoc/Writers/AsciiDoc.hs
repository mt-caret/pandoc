{-# LANGUAGE OverloadedStrings #-}
{- |
   Module      : Text.Pandoc.Writers.AsciiDoc
   Copyright   : Copyright (C) 2006-2022 John MacFarlane
   License     : GNU GPL, version 2 or above

   Maintainer  : John MacFarlane <jgm@berkeley.edu>
   Stability   : alpha
   Portability : portable

Conversion of 'Pandoc' documents to asciidoc.

Note that some information may be lost in conversion, due to
expressive limitations of asciidoc.  Footnotes and table cells with
paragraphs (or other block items) are not possible in asciidoc.
If pandoc encounters one of these, it will insert a message indicating
that it has omitted the construct.

AsciiDoc:  <http://www.methods.co.nz/asciidoc/>
-}
module Text.Pandoc.Writers.AsciiDoc (writeAsciiDoc, writeAsciiDoctor) where
import Control.Monad.State.Strict
import Data.Char (isPunctuation, isSpace)
import Data.List (delete, intercalate, intersperse)
import Data.List.NonEmpty (NonEmpty(..))
import Data.Maybe (fromMaybe, isJust)
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Text (Text)
import Text.Pandoc.Class.PandocMonad (PandocMonad, report)
import Text.Pandoc.Definition
import Text.Pandoc.ImageSize
import Text.Pandoc.Logging
import Text.Pandoc.Options
import Text.Pandoc.Parsing hiding (blankline, space)
import Text.DocLayout
import Text.Pandoc.Shared
import Text.Pandoc.Templates (renderTemplate)
import Text.Pandoc.Writers.Shared


data WriterState = WriterState { defListMarker       :: Text
                               , orderedListLevel    :: Int
                               , bulletListLevel     :: Int
                               , intraword           :: Bool
                               , autoIds             :: Set.Set Text
                               , asciidoctorVariant  :: Bool
                               , inList              :: Bool
                               , hasMath             :: Bool
                               --0 is no table
                               -- 1 is top level table
                               -- 2 is a table in a table
                               , tableNestingLevel   :: Int
                               }

defaultWriterState :: WriterState
defaultWriterState = WriterState { defListMarker      = "::"
                                 , orderedListLevel   = 0
                                 , bulletListLevel    = 0
                                 , intraword          = False
                                 , autoIds            = Set.empty
                                 , asciidoctorVariant = False
                                 , inList             = False
                                 , hasMath            = False
                                 , tableNestingLevel  = 0
                                 }

-- Convert Pandoc to AsciiDoc.
writeAsciiDoc :: PandocMonad m => WriterOptions -> Pandoc -> m Text
writeAsciiDoc opts document =
  evalStateT (pandocToAsciiDoc opts document) defaultWriterState

-- Convert Pandoc to AsciiDoctor compatible AsciiDoc.
writeAsciiDoctor :: PandocMonad m => WriterOptions -> Pandoc -> m Text
writeAsciiDoctor opts document =
  evalStateT (pandocToAsciiDoc opts document)
    defaultWriterState{ asciidoctorVariant = True }

type ADW = StateT WriterState

-- Return asciidoc representation of document.
pandocToAsciiDoc :: PandocMonad m => WriterOptions -> Pandoc -> ADW m Text
pandocToAsciiDoc opts (Pandoc meta blocks) = do
  let titleblock = not $ null (docTitle meta) && null (docAuthors meta) &&
                         null (docDate meta)
  let colwidth = if writerWrapText opts == WrapAuto
                    then Just $ writerColumns opts
                    else Nothing
  metadata <- metaToContext opts
              (blockListToAsciiDoc opts)
              (fmap chomp . inlineListToAsciiDoc opts)
              meta
  main <- blockListToAsciiDoc opts $ makeSections False (Just 1) blocks
  st <- get
  let context  = defField "body" main
               $ defField "toc"
                  (writerTableOfContents opts &&
                   isJust (writerTemplate opts))
               $ defField "math" (hasMath st)
               $ defField "titleblock" titleblock metadata
  return $ render colwidth $
    case writerTemplate opts of
       Nothing  -> main
       Just tpl -> renderTemplate tpl context

-- Escape special characters for AsciiDoc.
escapeString :: Text -> Text
escapeString t
  | T.any (== '{') t = T.concatMap escChar t
  | otherwise        = t
  where escChar '{' = "\\{"
        escChar c   = T.singleton c

-- Ordered list start parser for use in Para below.
olMarker :: Parser Text ParserState Char
olMarker = do (start, style', delim) <- anyOrderedListMarker
              if delim == Period &&
                          (style' == UpperAlpha || (style' == UpperRoman &&
                          start `elem` [1, 5, 10, 50, 100, 500, 1000]))
                          then spaceChar >> spaceChar
                          else spaceChar

-- True if string begins with an ordered list marker
-- or would be interpreted as an AsciiDoc option command
needsEscaping :: Text -> Bool
needsEscaping s = beginsWithOrderedListMarker s || isBracketed s
  where
    beginsWithOrderedListMarker str =
      case runParser olMarker defaultParserState "para start" (T.take 10 str) of
             Left  _ -> False
             Right _ -> True
    isBracketed t
      | Just ('[', t') <- T.uncons t
      , Just (_, ']')  <- T.unsnoc t'
      = True
      | otherwise = False

-- Convert Pandoc block element to asciidoc.
blockToAsciiDoc :: PandocMonad m
                => WriterOptions -- ^ Options
                -> Block         -- ^ Block element
                -> ADW m (Doc Text)
blockToAsciiDoc _ Null = return empty
blockToAsciiDoc opts (Div (id',"section":_,_)
                       (Header level (_,cls,kvs) ils : xs)) = do
  hdr <- blockToAsciiDoc opts (Header level (id',cls,kvs) ils)
  rest <- blockListToAsciiDoc opts xs
  return $ hdr $$ rest
blockToAsciiDoc opts (Plain inlines) = do
  contents <- inlineListToAsciiDoc opts inlines
  return $ contents <> blankline
blockToAsciiDoc opts (SimpleFigure attr alternate (src, tit))
  -- image::images/logo.png[Company logo, title="blah"]
  = (\args -> "image::" <> args <> blankline) <$>
    imageArguments opts attr alternate src tit
blockToAsciiDoc opts (Para inlines) = do
  contents <- inlineListToAsciiDoc opts inlines
  -- escape if para starts with ordered list marker
  let esc = if needsEscaping (render Nothing contents)
               then text "{empty}"
               else empty
  return $ esc <> contents <> blankline
blockToAsciiDoc opts (LineBlock lns) = do
  let docify line = if null line
                    then return blankline
                    else inlineListToAsciiDoc opts line
  let joinWithLinefeeds = nowrap . mconcat . intersperse cr
  contents <- joinWithLinefeeds <$> mapM docify lns
  return $ "[verse]" $$ text "--" $$ contents $$ text "--" $$ blankline
blockToAsciiDoc _ b@(RawBlock f s)
  | f == "asciidoc" = return $ literal s
  | otherwise         = do
      report $ BlockNotRendered b
      return empty
blockToAsciiDoc _ HorizontalRule =
  return $ blankline <> text "'''''" <> blankline
blockToAsciiDoc opts (Header level (ident,_,_) inlines) = do
  contents <- inlineListToAsciiDoc opts inlines
  ids <- gets autoIds
  let autoId = uniqueIdent (writerExtensions opts) inlines ids
  modify $ \st -> st{ autoIds = Set.insert autoId ids }
  let identifier = if T.null ident ||
                      (isEnabled Ext_auto_identifiers opts && ident == autoId)
                      then empty
                      else "[[" <> literal ident <> "]]"
  return $ identifier $$
           nowrap (text (replicate (level + 1) '=') <> space <> contents) <>
           blankline

blockToAsciiDoc _ (CodeBlock (_,classes,_) str) = return $ flush (
  if null classes
     then "...." $$ literal str $$ "...."
     else attrs $$ "----" $$ literal str $$ "----")
  <> blankline
    where attrs = "[" <> literal (T.intercalate "," classes') <> "]"
          classes' = if "numberLines" `elem` classes
                        then "source%linesnum" : delete "numberLines" classes
                        else "source" : classes
blockToAsciiDoc opts (BlockQuote blocks) = do
  contents <- blockListToAsciiDoc opts blocks
  let isBlock (BlockQuote _) = True
      isBlock _              = False
  -- if there are nested block quotes, put in an open block
  let contents' = if any isBlock blocks
                     then "--" $$ contents $$ "--"
                     else contents
  let bar = text "____"
  return $ bar $$ chomp contents' $$ bar <> blankline
blockToAsciiDoc opts block@(Table _ blkCapt specs thead tbody tfoot) = do
  let (caption, aligns, widths, headers, rows) =
        toLegacyTable blkCapt specs thead tbody tfoot
  caption' <- inlineListToAsciiDoc opts caption
  let caption'' = if null caption
                     then empty
                     else "." <> caption' <> cr
  let isSimple = all (== 0) widths
  let relativePercentWidths = if isSimple
                                 then widths
                                 else map (/ sum widths) widths
  let widths'' :: [Integer]
      widths'' = map (floor . (* 100)) relativePercentWidths
  -- ensure that the widths sum to 100
  let widths' = case widths'' of
                     _ | isSimple -> widths''
                     (w:ws) | sum (w:ws) < 100
                               -> (100 - sum ws) : ws
                     ws        -> ws
  let totalwidth :: Integer
      totalwidth = floor $ sum widths * 100
  let colspec al wi = (case al of
                         AlignLeft    -> "<"
                         AlignCenter  -> "^"
                         AlignRight   -> ">"
                         AlignDefault -> "") ++
                      if wi == 0 then "" else show wi ++ "%"
  let headerspec = if all null headers
                      then empty
                      else text "options=\"header\","
  let widthspec = if totalwidth == 0
                     then empty
                     else text "width="
                          <> doubleQuotes (text $ show totalwidth ++ "%")
                          <> text ","
  let tablespec = text "["
         <> widthspec
         <> text "cols="
         <> doubleQuotes (text $ intercalate ","
             $ zipWith colspec aligns widths')
         <> text ","
         <> headerspec <> text "]"
         
  -- construct cells and recurse in case of nested tables
  parentTableLevel <- gets tableNestingLevel
  let currentNestingLevel = parentTableLevel + 1
  
  modify $ \st -> st{ tableNestingLevel = currentNestingLevel }
  
  let separator = text (if parentTableLevel == 0
                          then "|"  -- top level separator
                          else "!") -- nested separator

  let makeCell [Plain x] = do d <- blockListToAsciiDoc opts [Plain x]
                              return $ separator <> chomp d
      makeCell [Para x]  = makeCell [Plain x]
      makeCell []        = return separator
      makeCell bs        = if currentNestingLevel == 2
                             then do
                               --asciidoc only supports nesting once
                               report $ BlockNotRendered block
                               return separator
                             else do
                               d <- blockListToAsciiDoc opts bs
                               return $ (text "a" <> separator) $$ d

  let makeRow cells = hsep `fmap` mapM makeCell cells
  rows' <- mapM makeRow rows
  head' <- makeRow headers
  modify $ \st -> st{ tableNestingLevel = parentTableLevel }
  let head'' = if all null headers then empty else head'
  let colwidth = if writerWrapText opts == WrapAuto
                    then writerColumns opts
                    else 100000
  let maxwidth = maximum $ fmap offset (head' :| rows')
  let body = if maxwidth > colwidth then vsep rows' else vcat rows'
  let border = separator <> text "==="
  return $ 
    caption'' $$ tablespec $$ border $$ head'' $$ body $$ border $$ blankline
blockToAsciiDoc opts (BulletList items) = do
  inlist <- gets inList
  modify $ \st -> st{ inList = True }
  contents <- mapM (bulletListItemToAsciiDoc opts) items
  modify $ \st -> st{ inList = inlist }
  return $ mconcat contents <> blankline
blockToAsciiDoc opts (OrderedList (start, sty, _delim) items) = do
  let listStyle = case sty of
                       DefaultStyle -> []
                       Decimal      -> ["arabic"]
                       Example      -> []
                       _            -> [T.toLower (tshow sty)]
  let listStart = ["start=" <> tshow start | start /= 1]
  let listoptions = case T.intercalate ", " (listStyle ++ listStart) of
                          "" -> empty
                          x  -> brackets (literal x)
  inlist <- gets inList
  modify $ \st -> st{ inList = True }
  contents <- mapM (orderedListItemToAsciiDoc opts) items
  modify $ \st -> st{ inList = inlist }
  return $ listoptions $$ mconcat contents <> blankline
blockToAsciiDoc opts (DefinitionList items) = do
  inlist <- gets inList
  modify $ \st -> st{ inList = True }
  contents <- mapM (definitionListItemToAsciiDoc opts) items
  modify $ \st -> st{ inList = inlist }
  return $ mconcat contents <> blankline
blockToAsciiDoc opts (Div (ident,classes,_) bs) = do
  let identifier = if T.null ident then empty else "[[" <> literal ident <> "]]"
  let admonitions = ["attention","caution","danger","error","hint",
                     "important","note","tip","warning"]
  contents <-
       case classes of
         (l:_) | l `elem` admonitions -> do
             let (titleBs, bodyBs) =
                     case bs of
                       (Div (_,["title"],_) ts : rest) -> (ts, rest)
                       _ -> ([], bs)
             admonitionTitle <- if null titleBs
                                   then return mempty
                                   else ("." <>) <$>
                                         blockListToAsciiDoc opts titleBs
             admonitionBody <- blockListToAsciiDoc opts bodyBs
             return $ "[" <> literal (T.toUpper l) <> "]" $$
                      chomp admonitionTitle $$
                      "====" $$
                      chomp admonitionBody $$
                      "===="
         _ -> blockListToAsciiDoc opts bs
  return $ identifier $$ contents $$ blankline

-- Convert bullet list item (list of blocks) to asciidoc.
bulletListItemToAsciiDoc :: PandocMonad m
                         => WriterOptions -> [Block] -> ADW m (Doc Text)
bulletListItemToAsciiDoc opts blocks = do
  lev <- gets bulletListLevel
  modify $ \s -> s{ bulletListLevel = lev + 1 }
  contents <- foldM (addBlock opts) empty blocks
  modify $ \s -> s{ bulletListLevel = lev }
  let marker = text (replicate (lev + 1) '*')
  return $ marker <> text " " <> listBegin blocks <>
    contents <> cr

addBlock :: PandocMonad m
         => WriterOptions -> Doc Text -> Block -> ADW m (Doc Text)
addBlock opts d b = do
  x <- chomp <$> blockToAsciiDoc opts b
  return $
    case b of
        BulletList{} -> d <> cr <> x
        OrderedList{} -> d <> cr <> x
        Para (Math DisplayMath _:_) -> d <> cr <> x
        Plain (Math DisplayMath _:_) -> d <> cr <> x
        Para{} | isEmpty d -> x
        Plain{} | isEmpty d -> x
        _ -> d <> cr <> text "+" <> cr <> x

listBegin :: [Block] -> Doc Text
listBegin blocks =
        case blocks of
          Para (Math DisplayMath _:_) : _  -> "{blank}"
          Plain (Math DisplayMath _:_) : _ -> "{blank}"
          Para _ : _                       -> empty
          Plain _ : _                      -> empty
          _ : _                            -> "{blank}"
          []                               -> "{blank}"

-- Convert ordered list item (a list of blocks) to asciidoc.
orderedListItemToAsciiDoc :: PandocMonad m
                          => WriterOptions -- ^ options
                          -> [Block]       -- ^ list item (list of blocks)
                          -> ADW m (Doc Text)
orderedListItemToAsciiDoc opts blocks = do
  lev <- gets orderedListLevel
  modify $ \s -> s{ orderedListLevel = lev + 1 }
  contents <- foldM (addBlock opts) empty blocks
  modify $ \s -> s{ orderedListLevel = lev }
  let marker = text (replicate (lev + 1) '.')
  return $ marker <> text " " <> listBegin blocks <> contents <> cr

-- Convert definition list item (label, list of blocks) to asciidoc.
definitionListItemToAsciiDoc :: PandocMonad m
                             => WriterOptions
                             -> ([Inline],[[Block]])
                             -> ADW m (Doc Text)
definitionListItemToAsciiDoc opts (label, defs) = do
  labelText <- inlineListToAsciiDoc opts label
  marker <- gets defListMarker
  if marker == "::"
     then modify (\st -> st{ defListMarker = ";;"})
     else modify (\st -> st{ defListMarker = "::"})
  let divider = cr <> text "+" <> cr
  let defsToAsciiDoc :: PandocMonad m => [Block] -> ADW m (Doc Text)
      defsToAsciiDoc ds = (vcat . intersperse divider . map chomp)
           `fmap` mapM (blockToAsciiDoc opts) ds
  defs' <- mapM defsToAsciiDoc defs
  modify (\st -> st{ defListMarker = marker })
  let contents = nest 2 $ vcat $ intersperse divider $ map chomp defs'
  return $ labelText <> literal marker <> cr <> contents <> cr

-- Convert list of Pandoc block elements to asciidoc.
blockListToAsciiDoc :: PandocMonad m
                    => WriterOptions -- ^ Options
                    -> [Block]       -- ^ List of block elements
                    -> ADW m (Doc Text)
blockListToAsciiDoc opts blocks =
  mconcat `fmap` mapM (blockToAsciiDoc opts) blocks

data SpacyLocation = End | Start

-- Convert list of Pandoc inline elements to asciidoc.
inlineListToAsciiDoc :: PandocMonad m =>
                        WriterOptions ->
                        [Inline] ->
                        ADW m (Doc Text)
inlineListToAsciiDoc opts lst = do
  oldIntraword <- gets intraword
  setIntraword False
  result <- go lst
  setIntraword oldIntraword
  return result
 where go [] = return empty
       go (y:x:xs)
         | not (isSpacy End y) = do
           y' <- if isSpacy Start x
                    then inlineToAsciiDoc opts y
                    else withIntraword $ inlineToAsciiDoc opts y
           x' <- withIntraword $ inlineToAsciiDoc opts x
           xs' <- go xs
           return (y' <> x' <> xs')
         | not (isSpacy Start x) = do
           y' <- withIntraword $ inlineToAsciiDoc opts y
           xs' <- go (x:xs)
           return (y' <> xs')
       go (x:xs) = do
           x' <- inlineToAsciiDoc opts x
           xs' <- go xs
           return (x' <> xs')
       isSpacy :: SpacyLocation -> Inline -> Bool
       isSpacy _ Space = True
       isSpacy _ LineBreak = True
       isSpacy _ SoftBreak = True
       -- Note that \W characters count as spacy in AsciiDoc
       -- for purposes of determining interword:
       isSpacy End (Str xs) = case T.unsnoc xs of
                                   Just (_, c) -> isPunctuation c || isSpace c
                                   _           -> False
       isSpacy Start (Str xs)
         | Just (c, _) <- T.uncons xs = isPunctuation c || isSpace c
       isSpacy _ _ = False

setIntraword :: PandocMonad m => Bool -> ADW m ()
setIntraword b = modify $ \st -> st{ intraword = b }

withIntraword :: PandocMonad m => ADW m a -> ADW m a
withIntraword p = setIntraword True *> p <* setIntraword False

-- Convert Pandoc inline element to asciidoc.
inlineToAsciiDoc :: PandocMonad m => WriterOptions -> Inline -> ADW m (Doc Text)
inlineToAsciiDoc opts (Emph [Strong xs]) =
  inlineToAsciiDoc opts (Strong [Emph xs])  -- see #5565
inlineToAsciiDoc opts (Emph lst) = do
  contents <- inlineListToAsciiDoc opts lst
  isIntraword <- gets intraword
  let marker = if isIntraword then "__" else "_"
  return $ marker <> contents <> marker
inlineToAsciiDoc opts (Underline lst) = do
  contents <- inlineListToAsciiDoc opts lst
  return $ "+++" <> contents <> "+++"
inlineToAsciiDoc opts (Strong lst) = do
  contents <- inlineListToAsciiDoc opts lst
  isIntraword <- gets intraword
  let marker = if isIntraword then "**" else "*"
  return $ marker <> contents <> marker
inlineToAsciiDoc opts (Strikeout lst) = do
  contents <- inlineListToAsciiDoc opts lst
  return $ "[line-through]*" <> contents <> "*"
inlineToAsciiDoc opts (Superscript lst) = do
  contents <- inlineListToAsciiDoc opts lst
  return $ "^" <> contents <> "^"
inlineToAsciiDoc opts (Subscript lst) = do
  contents <- inlineListToAsciiDoc opts lst
  return $ "~" <> contents <> "~"
inlineToAsciiDoc opts (SmallCaps lst) = inlineListToAsciiDoc opts lst
inlineToAsciiDoc opts (Quoted qt lst) = do
  isAsciidoctor <- gets asciidoctorVariant
  inlineListToAsciiDoc opts $
    case qt of
      SingleQuote
        | isAsciidoctor -> [Str "'`"] ++ lst ++ [Str "`'"]
        | otherwise     -> [Str "`"] ++ lst ++ [Str "'"]
      DoubleQuote
        | isAsciidoctor -> [Str "\"`"] ++ lst ++ [Str "`\""]
        | otherwise     -> [Str "``"] ++ lst ++ [Str "''"]
inlineToAsciiDoc _ (Code _ str) = do
  isAsciidoctor <- gets asciidoctorVariant
  let escChar '`' = "\\'"
      escChar c   = T.singleton c
  let contents = literal (T.concatMap escChar str)
  return $
    if isAsciidoctor
       then text "`+" <> contents <> "+`"
       else text "`"  <> contents <> "`"
inlineToAsciiDoc _ (Str str) = return $ literal $ escapeString str
inlineToAsciiDoc _ (Math InlineMath str) = do
  isAsciidoctor <- gets asciidoctorVariant
  modify $ \st -> st{ hasMath = True }
  let content = if isAsciidoctor
                then literal str
                else "$" <> literal str <> "$"
  return $ "latexmath:[" <> content <> "]"
inlineToAsciiDoc _ (Math DisplayMath str) = do
  isAsciidoctor <- gets asciidoctorVariant
  modify $ \st -> st{ hasMath = True }
  let content = if isAsciidoctor
                then literal str
                else "\\[" <> literal str <> "\\]"
  inlist <- gets inList
  let sepline = if inlist
                   then text "+"
                   else blankline
  return $
      (cr <> sepline) $$ "[latexmath]" $$ "++++" $$
      content $$ "++++" <> cr
inlineToAsciiDoc _ il@(RawInline f s)
  | f == "asciidoc" = return $ literal s
  | otherwise         = do
      report $ InlineNotRendered il
      return empty
inlineToAsciiDoc _ LineBreak = return $ " +" <> cr
inlineToAsciiDoc _ Space = return space
inlineToAsciiDoc opts SoftBreak =
  case writerWrapText opts of
       WrapAuto     -> return space
       WrapPreserve -> return cr
       WrapNone     -> return space
inlineToAsciiDoc opts (Cite _ lst) = inlineListToAsciiDoc opts lst
inlineToAsciiDoc opts (Link _ txt (src, _tit)) = do
-- relative:  link:downloads/foo.zip[download foo.zip]
-- abs:  http://google.cod[Google]
-- or my@email.com[email john]
  linktext <- inlineListToAsciiDoc opts txt
  let isRelative = T.all (/= ':') src
  let needsPassthrough = "--" `T.isInfixOf` src
  let prefix = if isRelative
                  then text "link:"
                  else empty
  let srcSuffix = fromMaybe src (T.stripPrefix "mailto:" src)
  let useAuto = case txt of
                      [Str s] | escapeURI s == srcSuffix -> True
                      _       -> False
  return $
    if needsPassthrough
       then
         if useAuto
            then "link:++" <> literal srcSuffix <> "++[]"
            else "link:++" <> literal src <> "++[" <> linktext <> "]"
       else
         if useAuto
            then literal srcSuffix
            else prefix <> literal src <> "[" <> linktext <> "]"
inlineToAsciiDoc opts (Image attr alternate (src, tit)) =
  ("image:" <>) <$> imageArguments opts attr alternate src tit
inlineToAsciiDoc opts (Note [Para inlines]) =
  inlineToAsciiDoc opts (Note [Plain inlines])
inlineToAsciiDoc opts (Note [Plain inlines]) = do
  contents  <- inlineListToAsciiDoc opts inlines
  return $ text "footnote:[" <> contents <> "]"
-- asciidoc can't handle blank lines in notes
inlineToAsciiDoc _ (Note _) = return "[multiblock footnote omitted]"
inlineToAsciiDoc opts (Span (ident,classes,_) ils) = do
  contents <- inlineListToAsciiDoc opts ils
  isIntraword <- gets intraword
  let marker = if isIntraword then "##" else "#"
  if T.null ident && null classes
     then return contents
     else do
       let modifier = brackets $ literal $ T.unwords $
            [ "#" <> ident | not (T.null ident)] ++ map ("." <>) classes
       return $ modifier <> marker <> contents <> marker

-- Provides the arguments for both `image:` and `image::`
-- e.g.: sunset.jpg[Sunset,300,200]
imageArguments :: PandocMonad m => WriterOptions ->
  Attr -> [Inline] -> Text -> Text ->
  ADW m (Doc Text)
imageArguments opts attr altText src title = do
  let txt = if null altText || (altText == [Str ""])
               then [Str "image"]
               else altText
  linktext <- inlineListToAsciiDoc opts txt
  let linktitle = if T.null title
                     then empty
                     else ",title=\"" <> literal title <> "\""
      showDim dir = case dimension dir attr of
                      Just (Percent a) ->
                        ["scaledwidth=" <> text (show (Percent a))]
                      Just dim         ->
                        [text (show dir) <> "=" <>
                          literal (showInPixel opts dim)]
                      Nothing          ->
                        []
      dimList = showDim Width ++ showDim Height
      dims = if null dimList
                then empty
                else "," <> mconcat (intersperse "," dimList)
  return $ literal src <> "[" <> linktext <> linktitle <> dims <> "]"
