
 SET 'auto.offset.reset'='earliest';
  2
  3 -- { "LogNo": 143046805, "ServiceCode": "SVC041", "GameAccountNo": 25265314, "CashProductNo": 1297, "StoreCode": "ST    O001", "StoreProductID": "mua_dia55", "CashProductName": "(구글) 다이아 55개", "CashProductType": "CPT001", "CashPro    ductPrice": "AdTA", "CurrencyCode": "KRW", "TransactionID": "ED0489DF7C8543F69837ACA36031BCE5", "ApprovedID": "ADD62    3A5441240CBA70596FD9F084471", "OrderID": "GPA.3346-7000-0522-30727", "ReceiptReturnCode": null, "StepCode": "STP003"    , "StepResultCode": "1     ", "IP": "103.212.124.52", "RegDate": 1665414017787, "AdminID": null, "CountryCode": "kr"    , "LanguageCode": "ko", "PurchaseTime": null, "StoreCashProductPrice": null, "PurchaseToken": null, "IsTest": 0 }
  4 SET 'auto.offset.reset'='latest';
  5 CREATE STREAM purchase (
  6     LogNo BIGINT,
  7     ServiceCode VARCHAR ,
  8     GameAccountNo BIGINT,
  9     CashProductNo INT,
 10     LanguageCode VARCHAR,
 11     RegDate TIMESTAMP
 12     )
 13 WITH (kafka_topic='test_221012_t_purchaseprocesslog_kst', value_format='json');
 14
 15
 16 -- { "UpdateTime": 1666606978743, "TableName": "T_CashProductDesc", "CashProductNo": 1, "CashProductName": "다이아 1    50개", "CashProductDesc": "다이아 150개", "LanguageCode": "ko" }
 17 CREATE STREAM cash_product_desc_raw (
 18     UpdateTime TIMESTAMP,
 19     CashProductNo INT,
 20     CashProductName VARCHAR
 21     )
 22 WITH (kafka_topic='kst_T_CashProductDesc', format='json');
 23
 24
 25 CREATE STREAM cash_product_desc
 26     WITH (kafka_topic='cash_product_desc', format='json')
 27     AS SELECT *
 28     FROM cash_product_desc_raw
 29     PARTITION BY CashProductNo;
 30
 31
 32 CREATE TABLE latest_cash_product_desc
 33   WITH (kafka_topic='latest_cash_product_desc', partitions=4, format='json')
 34   AS SELECT
 35     CashProductNo,
 36     LATEST_BY_OFFSET(CashProductName) CashProductName
 37   FROM cash_product_desc
 38   GROUP BY CashProductNo;
 39
 40
 41 -- 상품 구매와 상품 정보 JOIN
 42 CREATE STREAM purchase_and_product_desc
 43   AS SELECT
 44     LogNo,
 45     ServiceCode,
46     GameAccountNo,
 47     p.CashProductNo CashProductNo,
 48     d.CashProductName CashProductName,
 49     LanguageCode,
 50     RegDate
 51   FROM purchase p
 52   LEFT JOIN latest_cash_product_desc d ON p.CashProductNo = d.CashProductNo;
 53
 54
 55 -- 1시간 크기 10분 이동 윈도우로 상품별 판매 수 취합
 56 SET 'auto.offset.reset'='latest';
 57 CREATE TABLE hourly_purchased AS
 58     SELECT
 59         CashProductName,
 60         FORMAT_TIMESTAMP(FROM_UNIXTIME(WINDOWSTART), 'yyyy-MM-dd HH:mm:ss.SSS', 'Asia/Seoul') WSTART,
 61         FORMAT_TIMESTAMP(FROM_UNIXTIME(WINDOWEND), 'yyyy-MM-dd HH:mm:ss.SSS', 'Asia/Seoul') WEND,
 62         TIMESTAMPADD(MINUTES, 10, FROM_UNIXTIME(UNIX_TIMESTAMP())) WCUT,
 63         COUNT(*) count
 64     FROM purchase_and_product_desc
 65     WINDOW HOPPING (SIZE 1 HOURS, ADVANCE BY 10 MINUTES)
 66     GROUP BY CashProductName;
 67
 68
 69 -- 위 윈도우들 중 첫 번째 것만 선택
 70 SELECT CashProductName, WSTART, WEND, count
 71     FROM hourly_purchased
 72     WHERE FROM_UNIXTIME(WINDOWEND) < WCUT
 73     EMIT CHANGES;

