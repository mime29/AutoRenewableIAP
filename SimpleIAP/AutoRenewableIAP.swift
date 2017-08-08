//
//  SimpleIAP.swift
//  SimpleIAP
//
//  Created by Mikael on 07/08/2017.
//  Copyright © 2017 Mikael. All rights reserved.
//

import StoreKit

enum PurchaseStatus {
  case paid
  case canNotPay //iOS device setting
  case purchaseFailed
  case purchaseExpired
}

enum ReceiptStatus {
  case error(message:String)
  case exists(date:Date)
}

/**
 All you have to do is to setup:
 - sharedSecret
 - productIdentifier
 - call inDidFinishLaunchingStart()
 */
class AutoRenewableIAP: NSObject {
  static let shared = AutoRenewableIAP()

  let verifyReceiptURL = URL(string: "https://buy.itunes.apple.com/verifyReceipt")!

  // - secret is used to confirm receipts
  // - product identifier is your payment model id
  // see that on itunes connect
  internal let sharedSecret = ""
  internal let productIdentifier = ""

  internal let paymentQueue = SKPaymentQueue.default()
  internal var product:SKProduct?
  internal var productRequest:SKProductsRequest?
  internal var findProductBlock:((SKProduct?) -> Void)?
  internal var purchaseBlock:((PurchaseStatus)->Void)?
}

extension AutoRenewableIAP : SKProductsRequestDelegate {

  func findProduct(completion: @escaping ( (SKProduct?) -> Void) ) {
    let request = SKProductsRequest(productIdentifiers: Set([productIdentifier]))
    request.delegate = self
    request.start()
    productRequest = request
    findProductBlock = completion
  }

  func request(_ request: SKRequest, didFailWithError error: Error) {
    NSLog("Product or Receipt request failed \(error)")
    productRequest = nil
    findProductBlock?(nil)
  }

  func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
    if let foundProduct = response.products.first {
      product = foundProduct
    }
    productRequest = nil
    findProductBlock?(product)
  }
}

extension AutoRenewableIAP {
  func inDidFinishLaunchingStart() {
    paymentQueue.add(self)
    findProduct { (foundProduct) in
      if let prod = foundProduct {
        NSLog("IAP Product found and loaded: \(prod.productIdentifier)")
      } else { NSLog("IAP Product not found") }
    }
  }

  func purchase(completion: @escaping (PurchaseStatus)->Void ) {
    if let prod = product {
      if SKPaymentQueue.canMakePayments() {
        purchaseBlock = completion
        let payment = SKPayment(product: prod)
        paymentQueue.add(payment)
      } else {
        completion(.canNotPay)
      }
    }
  }

  func restorePurchase(completion: @escaping (PurchaseStatus)->Void) {
    purchaseBlock = completion
    paymentQueue.restoreCompletedTransactions()
  }

}

// We become observer of the payment queue here
extension AutoRenewableIAP: SKPaymentTransactionObserver {
  func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
    NSLog("\(transactions.count) Transactions received")
    //We take only one transaction TODO: need to check if multiple transactions can occur
    if let transaction = transactions.first(where: { $0.payment.productIdentifier == self.productIdentifier }) {
      switch transaction.transactionState {
      case .purchased, .restored:
        paymentQueue.finishTransaction(transaction)
        processReceipt()
        //TODO: Add product identifier to UserDefaults
      case .failed:
        NSLog("payment failed: \(transaction.error.debugDescription)")
        purchaseBlock?(.purchaseFailed)
        purchaseBlock = nil
      case .purchasing, .deferred:
        NSLog("processing transaction... please wait")
      }
    }
  }
}

extension AutoRenewableIAP {
  func processReceipt() {
    if let receiptURL = Bundle.main.appStoreReceiptURL, FileManager.default.fileExists(atPath: receiptURL.path) {
      let receiptReq = try! buildReceiptRequest(receiptURL)
      sendReceiptRequest(receiptReq, completion: { (receiptStatus) in
        switch receiptStatus {
        case .exists(let date):
          let now = Date()
          if now < date {
            //purchase is still valid
            self.purchaseBlock?(PurchaseStatus.paid)
            self.purchaseBlock = nil //dangerous?
          }
        case .error(let message):
          NSLog("receiptStatus error: \(message)")
          self.purchaseBlock?(PurchaseStatus.purchaseExpired)
        }
      })
    } else {
      //If receipt is not on the device, we retrieve it
      let receiptRequest = SKReceiptRefreshRequest(receiptProperties: nil)
      receiptRequest.delegate = self
      receiptRequest.start()
    }
  }

  private func buildReceiptRequest(_ receiptURL:URL) throws -> URLRequest {
    let receiptData = try Data(contentsOf: receiptURL)
    let jsonData = receiptData.base64EncodedString()
    let requestData = try JSONSerialization.data(withJSONObject: jsonData, options: JSONSerialization.WritingOptions(rawValue: 0))
    let password = try JSONSerialization.data(withJSONObject: sharedSecret, options: JSONSerialization.WritingOptions(rawValue: 0))
    let payload = ["receipt-data": requestData, "password": password]
    let serializedPayload = try JSONSerialization.data(withJSONObject: payload, options: JSONSerialization.WritingOptions.prettyPrinted)

    var request = URLRequest(url: verifyReceiptURL)
    request.httpMethod = "POST"
    request.httpBody = serializedPayload

    return request
  }

  private func sendReceiptRequest(_ receiptRequest: URLRequest, completion: @escaping ((ReceiptStatus)->Void)) {
    URLSession.shared.dataTask(with: receiptRequest) { (data, response, error) in
      guard error == nil else {
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        let errCodeString = statusCode == nil ? "" : "\(statusCode!)"
        completion(.error(message: errCodeString))
        return
      }
      guard data != nil else {
        completion(.error(message: "no response from Receipt request"))
        return
      }
      if let receiptDate = self.parseResponse(data!) {
        completion(.exists(date: receiptDate))
      } else {
        completion(.error(message: "no receipt date found"))
      }
    }
  }

  private func parseResponse(_ jsonData: Data) -> Date? {
    if let jsonObj = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] {
      if let receipt = (jsonObj?["latest_receipt_info"] as? [[String: Any]])?.last {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss VV"
        if let receiptDateStr = receipt["expires_date"] as? String {
          let date = formatter.date(from: receiptDateStr)
          return date
        }
      }
    }
    return nil
  }

}

//Helpers
extension AutoRenewableIAP {
  func isPurchaseActive() -> Bool {

  }
}
