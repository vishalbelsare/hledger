{-# LANGUAGE TemplateHaskell, QuasiQuotes, OverloadedStrings #-}
{-

hledger-web's request handlers, and helpers.

-}

module Handlers where

import Control.Applicative ((<$>), (<*>))
import Data.Aeson
import Data.ByteString (ByteString)
import Data.Either (lefts,rights)
import Data.List
import Data.Maybe
import Data.Text(Text,pack,unpack)
import Data.Time.Calendar
import Data.Time.Clock
import Data.Time.Format
-- import Safe
import System.FilePath (takeFileName, (</>))
import System.IO.Storage (putValue, getValue)
import System.Locale (defaultTimeLocale)
import Text.Hamlet hiding (hamletFile)
import Text.Printf
import Yesod.Form
import Yesod.Json

import Hledger.Cli
import Hledger.Data hiding (today)
import Hledger.Read (journalFromPathAndString)
import Hledger.Read.JournalReader (someamount)
import Hledger.Utils

import App
import Settings


getFaviconR :: Handler ()
getFaviconR = sendFile "image/x-icon" $ Settings.staticdir </> "favicon.ico"

getRobotsR :: Handler RepPlain
getRobotsR = return $ RepPlain $ toContent ("User-agent: *" :: ByteString)

getRootR :: Handler RepHtml
getRootR = redirect RedirectTemporary defaultroute where defaultroute = RegisterR

----------------------------------------------------------------------
-- main views

-- | The journal entries view, with accounts sidebar.
getJournalR :: Handler RepHtml
getJournalR = do
  vd@VD{opts=opts,m=m,am=am,j=j} <- getViewData
  let
      sidecontent = balanceReportAsHtml opts vd $ balanceReport2 opts am j
      title = "Journal entries" ++ if m /= MatchAny then ", filtered" else "" :: String
      maincontent = journalReportAsHtml opts vd $ journalReport opts nullfilterspec $ filterJournalTransactions2 m j
  defaultLayout $ do
      setTitle "hledger-web journal"
      addHamlet [$hamlet|
^{topbar vd}
<div#content
 <div#sidebar
  ^{sidecontent}
 <div#main.journal
  <h2#contenttitle>#{title}
  ^{searchform vd}
  <div#maincontent
   ^{maincontent}
  ^{addform vd}
  ^{editform vd}
  ^{importform}
|]

-- | The journal entries view with no sidebar.
getJournalOnlyR :: Handler RepHtml
getJournalOnlyR = do
  vd@VD{opts=opts,m=m,j=j} <- getViewData
  defaultLayout $ do
      setTitle "hledger-web journal only"
      addHamlet $ journalReportAsHtml opts vd $ journalReport opts nullfilterspec $ filterJournalTransactions2 m j

-- | The main journal/account register view, with accounts sidebar.
getRegisterR :: Handler RepHtml
getRegisterR = do
  vd@VD{opts=opts,qopts=qopts,m=m,am=am,j=j} <- getViewData
  let sidecontent = balanceReportAsHtml opts vd $ balanceReport2 opts am j
      -- XXX like registerReportAsHtml
      inacct = inAccount qopts
      -- injournal = isNothing inacct
      filtering = m /= MatchAny
      -- showlastcolumn = if injournal && not filtering then False else True
      title = case inacct of
                Nothing       -> "Journal"++filter
                Just (a,subs) -> "Transactions in "++a++andsubs++filter
                                  where andsubs = if subs then " (and subaccounts)" else ""
                where
                  filter = if filtering then ", filtered" else ""
      maincontent =
          case inAccountMatcher qopts of Just m' -> registerReportAsHtml opts vd $ accountRegisterReport opts j m m'
                                         Nothing -> registerReportAsHtml opts vd $ journalRegisterReport opts j m
  defaultLayout $ do
      setTitle "hledger-web register"
      addHamlet [$hamlet|
^{topbar vd}
<div#content
 <div#sidebar
  ^{sidecontent}
 <div#main.register
  <h2#contenttitle>#{title}
  ^{searchform vd}
  <div#maincontent
   ^{maincontent}
  ^{addform vd}
  ^{editform vd}
  ^{importform}
|]

-- | The register view with no sidebar.
getRegisterOnlyR :: Handler RepHtml
getRegisterOnlyR = do
  vd@VD{opts=opts,qopts=qopts,m=m,j=j} <- getViewData
  defaultLayout $ do
      setTitle "hledger-web register only"
      addHamlet $
          case inAccountMatcher qopts of Just m' -> registerReportAsHtml opts vd $ accountRegisterReport opts j m m'
                                         Nothing -> registerReportAsHtml opts vd $ journalRegisterReport opts j m

-- | A simple accounts view. This one is json-capable, returning the chart
-- of accounts as json if the Accept header specifies json.
getAccountsR :: Handler RepHtmlJson
getAccountsR = do
  vd@VD{opts=opts,m=m,am=am,j=j} <- getViewData
  let j' = filterJournalPostings2 m j
      html = do
        setTitle "hledger-web accounts"
        addHamlet $ balanceReportAsHtml opts vd $ balanceReport2 opts am j'
      json = jsonMap [("accounts", toJSON $ journalAccountNames j')]
  defaultLayoutJson html json

-- | A json-only version of "getAccountsR", does not require the special Accept header.
getAccountsJsonR :: Handler RepJson
getAccountsJsonR = do
  VD{m=m,j=j} <- getViewData
  let j' = filterJournalPostings2 m j
  jsonToRepJson $ jsonMap [("accounts", toJSON $ journalAccountNames j')]

----------------------------------------------------------------------
-- view helpers

-- | Render a "BalanceReport" as HTML.
balanceReportAsHtml :: [Opt] -> ViewData -> BalanceReport -> Hamlet AppRoute
balanceReportAsHtml _ vd@VD{qopts=qopts,j=j} (items',total) =
 [$hamlet|
<div#accountsheading
 <a#accounts-toggle-link.togglelink href="#" title="Toggle sidebar">[+/-]
<div#accounts
 <table.balancereport>
  <tr
   <td.add colspan=3
    <br>
    <a#addformlink href onclick="return addformToggle(event)" title="Add a new transaction to the journal">Add a transaction..

  <tr.item :allaccts:.inacct
   <td.journal colspan=3
    <br>
    <a href=@{RegisterR} title="Show all transactions in journal format">Journal
    <span.hoverlinks
     &nbsp;
     <a href=@{JournalR} title="Show raw journal entries">entries</a>
     &nbsp;
     <a#editformlink href onclick="return editformToggle(event)" title="Edit the journal">edit

  <tr
   <td colspan=3
    <br>
    Accounts

  $forall i <- items
   ^{itemAsHtml vd i}

  <tr.totalrule>
   <td colspan=2>
  <tr>
   <td>
   <td align=right>#{mixedAmountAsHtml total}
|]
 where
   l = journalToLedger nullfilterspec j
   inacctmatcher = inAccountMatcher qopts
   allaccts = isNothing inacctmatcher
   items = items' -- maybe items' (\m -> filter (matchesAccount m . \(a,_,_,_)->a) items') showacctmatcher
   itemAsHtml :: ViewData -> BalanceReportItem -> Hamlet AppRoute
   itemAsHtml _ (acct, adisplay, aindent, abal) = [$hamlet|
<tr.item.#{inacctclass}
 <td.account.#{depthclass}
  #{indent}
  <a href="@?{acctquery}" title="Show transactions in this account, including subaccounts">#{adisplay}
  <span.hoverlinks
   $if hassubs
    &nbsp;
    <a href="@?{acctonlyquery}" title="Show transactions in this account only">only
   <!--
    &nbsp;
    <a href="@?{acctsonlyquery}" title="Focus on this account and sub-accounts and hide others">-others -->

 <td.balance align=right>#{mixedAmountAsHtml abal}
 <td.numpostings align=right title="#{numpostings} transactions in this account">(#{numpostings})
|]
     where
       hassubs = not $ null $ ledgerSubAccounts l $ ledgerAccount l acct
       numpostings = length $ apostings $ ledgerAccount l acct
       depthclass = "depth"++show aindent
       inacctclass = case inacctmatcher of
                       Just m -> if m `matchesAccount` acct then "inacct" else "notinacct"
                       Nothing -> "" :: String
       indent = preEscapedString $ concat $ replicate (2 * aindent) "&nbsp;"
       acctquery = (RegisterR, [("q", pack $ accountQuery acct)])
       acctonlyquery = (RegisterR, [("q", pack $ accountOnlyQuery acct)])

accountQuery :: AccountName -> String
accountQuery a = "inacct:" ++ quoteIfSpaced a -- (accountNameToAccountRegex a)

accountOnlyQuery :: AccountName -> String
accountOnlyQuery a = "inacctonly:" ++ quoteIfSpaced a -- (accountNameToAccountRegex a)

-- accountUrl :: AppRoute -> AccountName -> (AppRoute,[(String,ByteString)])
accountUrl r a = (r, [("q",pack $ accountQuery a)])

-- | Render a "JournalReport" as HTML.
journalReportAsHtml :: [Opt] -> ViewData -> JournalReport -> Hamlet AppRoute
journalReportAsHtml _ vd items = [$hamlet|
<table.journalreport>
 $forall i <- numbered items
  ^{itemAsHtml vd i}
 |]
 where
   itemAsHtml :: ViewData -> (Int, JournalReportItem) -> Hamlet AppRoute
   itemAsHtml _ (n, t) = [$hamlet|
<tr.item.#{evenodd}>
 <td.transaction>
  <pre>#{txn}
 |]
     where
       evenodd = if even n then "even" else "odd" :: String
       txn = trimnl $ showTransaction t where trimnl = reverse . dropWhile (=='\n') . reverse

-- Render an "AccountRegisterReport" as html, for the journal/account register views.
registerReportAsHtml :: [Opt] -> ViewData -> AccountRegisterReport -> Hamlet AppRoute
registerReportAsHtml _ vd@VD{m=m,qopts=qopts} (balancelabel,items) = [$hamlet|
$if showlastcolumn
 <script type=text/javascript>
  $(document).ready(function() {
    /* render chart */
    /* if ($('#register-chart')) */
      $.plot($('#register-chart'),
             [
              [
               $forall i <- items
                [#{dayToJsTimestamp $ ariDate i}, #{ariBalance i}],
              ]
             ],
             {
               xaxis: {
                mode: "time",
                timeformat: "%y/%m/%d"
               }
             }
             );
  });
 <div#register-chart style="width:600px;height:100px; margin-bottom:1em;"

<table.registerreport
 <tr.headings
  <th.date align=left>Date
  <th.description align=left>Description
  <th.account align=left>
    $if injournal
     Accounts
    $else
     To/From Account
    <!-- \ #
    <a#all-postings-toggle-link.togglelink href="#" title="Toggle all split postings">[+/-] -->
  <th.amount align=right>Amount
  $if showlastcolumn
   <th.balance align=right>#{balancelabel}

 $forall i <- numberAccountRegisterReportItems items
  ^{itemAsHtml vd i}
 |]
 where
   inacct = inAccount qopts
   filtering = m /= MatchAny
   injournal = isNothing inacct
   showlastcolumn = if injournal && not filtering then False else True
   itemAsHtml :: ViewData -> (Int, Bool, Bool, Bool, AccountRegisterReportItem) -> Hamlet AppRoute
   itemAsHtml VD{here=here,p=p} (n, newd, newm, _, (t, _, split, acct, amt, bal)) = [$hamlet|
<tr.item.#{evenodd}.#{firstposting}.#{datetransition}
 <td.date>#{date}
 <td.description title="#{show t}">#{elideRight 30 desc}
 <td.account title="#{show t}"
  $if True
   <a
    #{elideRight 40 acct}
   &nbsp;
   <a.postings-toggle-link.togglelink href="#" title="Toggle postings"
    [+/-]
  $else
   <a href="@?{acctquery}" title="Go to #{acct}">#{elideRight 40 acct}
 <td.amount align=right>
  $if showamt
   #{mixedAmountAsHtml amt}
 $if showlastcolumn
  <td.balance align=right>#{mixedAmountAsHtml bal}
$if True
 $forall p <- tpostings t
  <tr.item.#{evenodd}.posting.#{displayclass}
   <td.date
   <td.description
   <td.account>&nbsp;<a href="@?{accountUrl here $ paccount p}" title="Show transactions in #{paccount p}">#{elideRight 40 $ paccount p}
   <td.amount align=right>#{mixedAmountAsHtml $ pamount p}
   $if showlastcolumn
    <td.balance align=right>
|]
     where
       evenodd = if even n then "even" else "odd" :: String
       datetransition | newm = "newmonth"
                      | newd = "newday"
                      | otherwise = "" :: String
       (firstposting, date, desc) = (False, show $ tdate t, tdescription t)
       acctquery = (here, [("q", pack $ accountQuery acct)])
       showamt = not split || not (isZeroMixedAmount amt)
       displayclass = if p then "" else "hidden" :: String

stringIfLongerThan :: Int -> String -> String
stringIfLongerThan n s = if length s > n then s else ""

numberAccountRegisterReportItems :: [AccountRegisterReportItem] -> [(Int,Bool,Bool,Bool,AccountRegisterReportItem)]
numberAccountRegisterReportItems [] = []
numberAccountRegisterReportItems is = number 0 nulldate is
  where
    number :: Int -> Day -> [AccountRegisterReportItem] -> [(Int,Bool,Bool,Bool,AccountRegisterReportItem)]
    number _ _ [] = []
    number n prevd (i@(Transaction{tdate=d},_,_,_,_,_):is)  = (n+1,newday,newmonth,newyear,i):(number (n+1) d is)
        where
          newday = d/=prevd
          newmonth = dm/=prevdm || dy/=prevdy
          newyear = dy/=prevdy
          (dy,dm,_) = toGregorian d
          (prevdy,prevdm,_) = toGregorian prevd

mixedAmountAsHtml b = preEscapedString $ addclass $ intercalate "<br>" $ lines $ show b
    where addclass = printf "<span class=\"%s\">%s</span>" (c :: String)
          c = case isNegativeMixedAmount b of Just True -> "negative amount"
                                              _         -> "positive amount"

-------------------------------------------------------------------------------
-- post handlers

postJournalR :: Handler RepPlain
postJournalR = handlePost

postRegisterR :: Handler RepPlain
postRegisterR = handlePost

postJournalOnlyR :: Handler RepPlain
postJournalOnlyR = handlePost

postRegisterOnlyR :: Handler RepPlain
postRegisterOnlyR = handlePost

-- | Handle a post from any of the edit forms.
handlePost :: Handler RepPlain
handlePost = do
  action <- runFormPost' $ maybeStringInput "action"
  case action of Just "add"    -> handleAdd
                 Just "edit"   -> handleEdit
                 Just "import" -> handleImport
                 _             -> invalidArgs [pack "invalid action"]

-- | Handle a post from the transaction add form.
handleAdd :: Handler RepPlain
handleAdd = do
  VD{j=j,today=today} <- getViewData
  -- get form input values. M means a Maybe value.
  (dateM, descM, acct1M, amt1M, acct2M, amt2M, journalM) <- runFormPost'
    $ (,,,,,,)
    <$> maybeStringInput "date"
    <*> maybeStringInput "description"
    <*> maybeStringInput "account1"
    <*> maybeStringInput "amount1"
    <*> maybeStringInput "account2"
    <*> maybeStringInput "amount2"
    <*> maybeStringInput "journal"
  -- supply defaults and parse date and amounts, or get errors.
  let dateE = maybe (Left "date required") (either (\e -> Left $ showDateParseError e) Right . fixSmartDateStrEither today . unpack) dateM
      descE = Right $ maybe "" unpack descM
      acct1E = maybe (Left "to account required") (Right . unpack) acct1M
      acct2E = maybe (Left "from account required") (Right . unpack) acct2M
      amt1E = maybe (Left "amount required") (either (const $ Left "could not parse amount") Right . parseWithCtx nullctx someamount . unpack) amt1M
      amt2E = maybe (Right missingamt)       (either (const $ Left "could not parse amount") Right . parseWithCtx nullctx someamount . unpack) amt2M
      journalE = maybe (Right $ journalFilePath j)
                       (\f -> let f' = unpack f in
                              if f' `elem` journalFilePaths j
                              then Right f'
                              else Left $ "unrecognised journal file path: " ++ f'
                              )
                       journalM
      strEs = [dateE, descE, acct1E, acct2E, journalE]
      amtEs = [amt1E, amt2E]
      errs = lefts strEs ++ lefts amtEs
      [date,desc,acct1,acct2,journalpath] = rights strEs
      [amt1,amt2] = rights amtEs
      -- if no errors so far, generate a transaction and balance it or get the error.
      tE | not $ null errs = Left errs
         | otherwise = either (\e -> Left ["unbalanced postings: " ++ (head $ lines e)]) Right
                        (balanceTransaction Nothing $ nulltransaction { -- imprecise balancing
                           tdate=parsedate date
                          ,tdescription=desc
                          ,tpostings=[
                            Posting False acct1 amt1 "" RegularPosting [] Nothing
                           ,Posting False acct2 amt2 "" RegularPosting [] Nothing
                           ]
                          })
  -- display errors or add transaction
  case tE of
   Left errs -> do
    -- save current form values in session
    setMessage $ toHtml $ intercalate "; " errs
    redirect RedirectTemporary RegisterR

   Right t -> do
    let t' = txnTieKnot t -- XXX move into balanceTransaction
    liftIO $ appendToJournalFile journalpath $ showTransaction t'
    setMessage $ toHtml $ (printf "Added transaction:\n%s" (show t') :: String)
    redirect RedirectTemporary RegisterR

-- | Handle a post from the journal edit form.
handleEdit :: Handler RepPlain
handleEdit = do
  VD{j=j} <- getViewData
  -- get form input values, or validation errors.
  -- getRequest >>= liftIO (reqRequestBody req) >>= mtrace
  (textM, journalM) <- runFormPost'
    $ (,)
    <$> maybeStringInput "text"
    <*> maybeStringInput "journal"
  let textE = maybe (Left "No value provided") (Right . unpack) textM
      journalE = maybe (Right $ journalFilePath j)
                       (\f -> let f' = unpack f in
                              if f' `elem` journalFilePaths j
                              then Right f'
                              else Left "unrecognised journal file path")
                       journalM
      strEs = [textE, journalE]
      errs = lefts strEs
      [text,journalpath] = rights strEs
  -- display errors or perform edit
  if not $ null errs
   then do
    setMessage $ toHtml (intercalate "; " errs :: String)
    redirect RedirectTemporary JournalR

   else do
    -- try to avoid unnecessary backups or saving invalid data
    filechanged' <- liftIO $ journalSpecifiedFileIsNewer j journalpath
    told <- liftIO $ readFileStrictly journalpath
    let tnew = filter (/= '\r') text
        changed = tnew /= told || filechanged'
    if not changed
     then do
       setMessage "No change"
       redirect RedirectTemporary JournalR
     else do
      jE <- liftIO $ journalFromPathAndString Nothing journalpath tnew
      either
       (\e -> do
          setMessage $ toHtml e
          redirect RedirectTemporary JournalR)
       (const $ do
          liftIO $ writeFileWithBackup journalpath tnew
          setMessage $ toHtml (printf "Saved journal %s\n" (show journalpath) :: String)
          redirect RedirectTemporary JournalR)
       jE

-- | Handle a post from the journal import form.
handleImport :: Handler RepPlain
handleImport = do
  setMessage "can't handle file upload yet"
  redirect RedirectTemporary JournalR
  -- -- get form input values, or basic validation errors. E means an Either value.
  -- fileM <- runFormPost' $ maybeFileInput "file"
  -- let fileE = maybe (Left "No file provided") Right fileM
  -- -- display errors or import transactions
  -- case fileE of
  --  Left errs -> do
  --   setMessage errs
  --   redirect RedirectTemporary JournalR

  --  Right s -> do
  --    setMessage s
  --    redirect RedirectTemporary JournalR

----------------------------------------------------------------------
-- | Other view components.

-- | Global toolbar/heading area.
topbar :: ViewData -> Hamlet AppRoute
topbar VD{j=j,msg=msg} = [$hamlet|
<div#topbar
 <a.topleftlink href=#{hledgerorgurl} title="More about hledger"
  hledger-web
  <br />
  #{version}
 <a.toprightlink href=#{manualurl} target=hledgerhelp title="User manual">manual
 <h1>#{title}
$maybe m <- msg
 <div#message>#{m}
|]
  where
    title = takeFileName $ journalFilePath j

-- | Navigation link, preserving parameters and possibly highlighted.
navlink :: ViewData -> String -> AppRoute -> String -> Hamlet AppRoute
navlink VD{here=here,q=q} s dest title = [$hamlet|
<a##{s}link.#{style} href=@?{u} title="#{title}">#{s}
|]
  where u = (dest, if null q then [] else [("q", pack q)])
        style | dest == here = "navlinkcurrent"
              | otherwise    = "navlink" :: Text

-- | Links to the various journal editing forms.
editlinks :: Hamlet AppRoute
editlinks = [$hamlet|
<a#editformlink href onclick="return editformToggle(event)" title="Toggle journal edit form">edit
\ | #
<a#addformlink href onclick="return addformToggle(event)" title="Toggle transaction add form">add
<a#importformlink href onclick="return importformToggle(event)" style="display:none;">import transactions
|]

-- | Link to a topic in the manual.
helplink :: String -> String -> Hamlet AppRoute
helplink topic label = [$hamlet|
<a href=#{u} target=hledgerhelp>#{label}
|]
    where u = manualurl ++ if null topic then "" else '#':topic

-- | Search form for entering custom queries to filter journal data.
searchform :: ViewData -> Hamlet AppRoute
searchform VD{here=here,q=q} = [$hamlet|
<div#searchformdiv
 <form#searchform.form method=GET
  <table
   <tr
    <td
     Search:
     \ #
    <td
     <input name=q size=70 value=#{q}
     <input type=submit value="Search"
     $if filtering
      \ #
      <span.showall
       <a href=@{here}>clear search
     \ #
     <a#search-help-link href="#" title="Toggle search help">help
   <tr
    <td
    <td
     <div#search-help.help style="display:none;"
      Leave blank to see journal (all transactions), or click account links to see transactions under that account.
      <br>
      Transactions/postings may additionally be filtered by:
      <br>
      acct:REGEXP (target account), #
      desc:REGEXP (description), #
      date:PERIODEXP (date), #
      edate:PERIODEXP (effective date), #
      <br>
      status:BOOL (cleared status), #
      real:BOOL (real/virtual-ness), #
      empty:BOOL (posting amount = 0).
      <br>
      not: to negate, enclose space-containing patterns in quotes, multiple filters are AND'ed.
|]
 where
  filtering = not $ null q

-- | Add transaction form.
addform :: ViewData -> Hamlet AppRoute
addform vd@VD{qopts=qopts} = [$hamlet|
<script type=text/javascript>
 $(document).ready(function() {
    /* dhtmlxcombo setup */
    window.dhx_globalImgPath="../static/";
    var desccombo  = new dhtmlXCombo("description");
    var acct1combo = new dhtmlXCombo("account1");
    var acct2combo = new dhtmlXCombo("account2");
    desccombo.enableFilteringMode(true);
    acct1combo.enableFilteringMode(true);
    acct2combo.enableFilteringMode(true);
    desccombo.setSize(300);
    acct1combo.setSize(300);
    acct2combo.setSize(300);
    /* desccombo.enableOptionAutoHeight(true, 20); */
    /* desccombo.setOptionHeight(200); */
 });

<form#addform method=POST style=display:none;
  <h2#contenttitle>#{title}
  <table.form
   <tr
    <td colspan=4
     <table
      <tr#descriptionrow
       <td
        Date:
       <td
        <input.textinput size=15 name=date value=#{date}
       <td style=padding-left:1em;
        Description:
       <td
        <select id=description name=description
         <option
         $forall d <- descriptions
          <option value=#{d}>#{d}
      <tr.helprow
       <td
       <td
        <span.help>#{datehelp} #
       <td
       <td
        <span.help>#{deschelp}
   ^{postingfields vd 1}
   ^{postingfields vd 2}
   <tr#addbuttonrow
    <td colspan=4
     <input type=hidden name=action value=add
     <input type=submit name=submit value="add transaction"
     $if manyfiles
      \ to: ^{journalselect $ files $ j vd}
     \ or #
     <a href onclick="return addformToggle(event)">cancel
|]
 where
  title = "Add transaction" :: String
  datehelp = "eg: 2010/7/20" :: String
  deschelp = "eg: supermarket (optional)" :: String
  date = "today" :: String
  descriptions = sort $ nub $ map tdescription $ jtxns $ j vd
  manyfiles = (length $ files $ j vd) > 1
  postingfields VD{j=j} n = [$hamlet|
<tr#postingrow
 <td align=right>#{acctlabel}:
 <td
  <select id=#{acctvar} name=#{acctvar}
   <option
   $forall a <- acctnames
    <option value=#{a} :shouldselect a:selected>#{a}
 ^{amtfield}
<tr.helprow
 <td
 <td
  <span.help>#{accthelp}
 <td
 <td
  <span.help>#{amthelp}
|]
   where
    shouldselect a = n == 2 && maybe False ((a==).fst) (inAccount qopts)
    numbered = (++ show n)
    acctvar = numbered "account"
    amtvar = numbered "amount"
    acctnames = sort $ journalAccountNamesUsed j
    (acctlabel, accthelp, amtfield, amthelp)
       | n == 1     = ("To account"
                     ,"eg: expenses:food"
                     ,[$hamlet|
<td style=padding-left:1em;
 Amount:
<td
 <input.textinput size=15 name=#{amtvar} value=""
|]
                     ,"eg: $6"
                     )
       | otherwise = ("From account" :: String
                     ,"eg: assets:bank:checking" :: String
                     ,nulltemplate
                     ,"" :: String
                     )

-- | Edit journal form.
editform :: ViewData -> Hamlet AppRoute
editform VD{j=j} = [$hamlet|
<form#editform method=POST style=display:none;
 <table.form
  $if manyfiles
   <tr
    <td colspan=2
     Editing ^{journalselect $ files j}
  <tr
   <td colspan=2
    <!-- XXX textarea ids are unquoted journal file paths here, not valid html -->
    $forall f <- files j
     <textarea id=#{fst f}_textarea name=text rows=25 cols=80 style=display:none; disabled=disabled
      #{snd f}
  <tr#addbuttonrow
   <td
    <span.help>^{formathelp}
   <td align=right
    <span.help Are you sure ? This will overwrite the journal. #
    <input type=hidden name=action value=edit
    <input type=submit name=submit value="save journal"
    \ or #
    <a href onclick="return editformToggle(event)">cancel
|]
  where
    manyfiles = (length $ files j) > 1
    formathelp = helplink "file-format" "file format help"

-- | Import journal form.
importform :: Hamlet AppRoute
importform = [$hamlet|
<form#importform method=POST style=display:none;
 <table.form
  <tr
   <td
    <input type=file name=file
    <input type=hidden name=action value=import
    <input type=submit name=submit value="import from file"
    \ or #
    <a href onclick="return importformToggle(event)" cancel
|]

journalselect :: [(FilePath,String)] -> Hamlet AppRoute
journalselect journalfiles = [$hamlet|
<select id=journalselect name=journal onchange="editformJournalSelect(event)"
 $forall f <- journalfiles
  <option value=#{fst f}>#{fst f}
|]

nulltemplate :: Hamlet AppRoute
nulltemplate = [$hamlet||]

----------------------------------------------------------------------
-- utilities

-- | A bundle of data useful for hledger-web request handlers and templates.
data ViewData = VD {
     opts  :: [Opt]         -- ^ command-line options at startup
    ,q     :: String        -- ^ current q parameter, the query expression
    ,p     :: Bool          -- ^ current p parameter, 1 or 0 shows/hides all postings, default is based on query
    ,m     :: Matcher       -- ^ a matcher parsed from the main query expr ("q" parameter)
    ,qopts :: [QueryOpt]    -- ^ query options parsed from the main query expr
    ,am    :: Matcher       -- ^ a matcher parsed from the accounts sidebar query expr ("a" parameter)
    ,aopts :: [QueryOpt]    -- ^ query options parsed from the accounts sidebar query expr
    ,j     :: Journal       -- ^ the up-to-date parsed unfiltered journal
    ,today :: Day           -- ^ the current day
    ,here  :: AppRoute      -- ^ the current route
    ,msg   :: Maybe Html    -- ^ the current UI message if any, possibly from the current request
    }

mkvd :: ViewData
mkvd = VD {
      opts  = []
     ,q     = ""
     ,p     = False
     ,m     = MatchAny
     ,qopts = []
     ,am     = MatchAny
     ,aopts = []
     ,j     = nulljournal
     ,today = ModifiedJulianDay 0
     ,here  = RootR
     ,msg   = Nothing
     }

-- | Gather useful data for handlers and templates.
getViewData :: Handler ViewData
getViewData = do
  app        <- getYesod
  let opts = appOpts app
  (j, err)   <- getCurrentJournal opts
  msg        <- getMessageOr err
  Just here' <- getCurrentRoute
  today      <- liftIO getCurrentDay
  q          <- getParameter "q"
  let (querymatcher,queryopts) = parseQuery today q
  a          <- getParameter "a"
  let (acctsmatcher,acctsopts) = parseQuery today a
  p          <- getParameter "p"
  let p' | p == "1" = True
         | p == "0" = False
         | otherwise = isNothing $ inAccountMatcher queryopts
  return mkvd{opts=opts, q=q, p=p', m=querymatcher, qopts=queryopts, am=acctsmatcher, aopts=acctsopts, j=j, today=today, here=here', msg=msg}
    where
      -- | Update our copy of the journal if the file changed. If there is an
      -- error while reloading, keep the old one and return the error, and set a
      -- ui message.
      getCurrentJournal :: [Opt] -> Handler (Journal, Maybe String)
      getCurrentJournal opts = do
        j <- liftIO $ fromJust `fmap` getValue "hledger" "journal"
        (jE, changed) <- liftIO $ journalReloadIfChanged opts j
        if not changed
         then return (j,Nothing)
         else case jE of
                Right j' -> do liftIO $ putValue "hledger" "journal" j'
                               return (j',Nothing)
                Left e  -> do setMessage $ "error while reading" {- ++ ": " ++ e-}
                              return (j, Just e)

      -- | Get the named request parameter.
      getParameter :: String -> Handler String
      getParameter p = unpack `fmap` fromMaybe "" <$> lookupGetParam (pack p)

-- | Get the message set by the last request, or the newer message provided, if any.
getMessageOr :: Maybe String -> Handler (Maybe Html)
getMessageOr mnewmsg = do
  oldmsg <- getMessage
  return $ maybe oldmsg (Just . toHtml) mnewmsg

numbered = zip [1..]

dayToJsTimestamp :: Day -> Integer
dayToJsTimestamp d = read (formatTime defaultTimeLocale "%s" t) * 1000
                     where t = UTCTime d (secondsToDiffTime 0)
