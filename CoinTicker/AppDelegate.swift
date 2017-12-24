//
//  AppDelegate.swift
//  CoinTicker
//
//  Created by Alec Ananian on 5/30/17.
//  Copyright © 2017 Alec Ananian.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

import Cocoa
import Alamofire
import Fabric
import Crashlytics

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    @IBOutlet fileprivate var mainMenu: NSMenu!
    @IBOutlet private var exchangeMenuItem: NSMenuItem!
    @IBOutlet fileprivate var updateIntervalMenuItem: NSMenuItem!
    @IBOutlet private var currencyStartSeparator: NSMenuItem!
    @IBOutlet private var quitMenuItem: NSMenuItem!
    private var currencyMenuItems = [NSMenuItem]()
    private var currencyFormatter = NumberFormatter()
    
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let reachabilityManager = Alamofire.NetworkReachabilityManager()!
    
    private var currentExchange: Exchange! {
        didSet {
            TickerConfig.defaultExchangeSite = currentExchange.site
        }
    }
    
    // MARK: NSApplicationDelegate
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Start Fabric
        UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": true])
        if let resourceURL = Bundle.main.url(forResource: "fabric", withExtension: "apikey") {
            do {
                var apiKey = try String.init(contentsOf: resourceURL, encoding: .utf8)
                apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                Crashlytics.start(withAPIKey: apiKey)
            } catch {
                print("Error loading Fabric API key: \(error)")
            }
        }
        
        // Listen to workspace status notifications
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(onWorkspaceWillSleep(notification:)), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(onWorkspaceDidWake(notification:)), name: NSWorkspace.didWakeNotification, object: nil)
        
        // Listen to network reachability status
        reachabilityManager.listenerQueue = DispatchQueue(label: "cointicker.reachability", qos: .utility, attributes: [.concurrent])
        reachabilityManager.listener = { [unowned self] status in
            if status == .reachable(.ethernetOrWiFi) || status == .reachable(.wwan) {
                self.currentExchange?.load()
            } else {
                self.currentExchange?.stop()
                self.updateMenuWithOfflineText()
            }
        }
        
        // Set the main menu
        statusItem.menu = mainMenu
        
        // Load defaults
        TickerConfig.delegate = self
        currentExchange = Exchange.build(fromSite: TickerConfig.defaultExchangeSite, delegate: self)
        
        // Set up exchange sub-menu
        for exchangeSite in ExchangeSite.allValues {
            let item = NSMenuItem(title: exchangeSite.displayName, action: #selector(onSelectExchangeSite(sender:)), keyEquivalent: "")
            item.representedObject = exchangeSite
            item.state = (exchangeSite == currentExchange.site ? .on : .off)
            exchangeMenuItem.submenu?.addItem(item)
        }
        
        // Listen for network status
        reachabilityManager.startListening()
        if !reachabilityManager.isReachable {
            updateMenuWithOfflineText()
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        currentExchange?.stop()
    }
    
    // MARK: Notifications
    @objc private func onWorkspaceWillSleep(notification: Notification) {
        currentExchange?.stop()
    }
    
    @objc private func onWorkspaceDidWake(notification: Notification) {
        currentExchange?.fetch()
    }
    
    // MARK: UI Helpers
    private func updateMenuWithOfflineText() {
        DispatchQueue.main.async {
            self.statusItem.title = NSLocalizedString("menu.label.offline", comment: "Label to display when network connection fails")
            if self.statusItem.image == nil {
                self.statusItem.image = Currency.btc.iconImage
            }
        }
    }
    
    // MARK: UI Actions
    @objc private func onSelectExchangeSite(sender: AnyObject) {
        if let menuItem = sender as? NSMenuItem, let exchangeSite = menuItem.representedObject as? ExchangeSite {
            if exchangeSite != currentExchange.site {
                // End current exchange
                currentExchange.stop()
                
                // Deselect all exchange menu items and select this one
                exchangeMenuItem.submenu?.items.forEach({ $0.state = .off })
                menuItem.state = .on
                
                // Remove all currency selections
                currencyMenuItems.forEach({ mainMenu.removeItem($0) })
                currencyMenuItems.removeAll()
                
                // Start new exchange
                currentExchange = Exchange.build(fromSite: exchangeSite, delegate: self)
                currentExchange.load()
                
                // Track analytics
                TrackingUtils.didSelectExchange(exchangeSite)
            }
        }
    }
    
    @IBAction private func onSelectUpdateInterval(sender: AnyObject) {
        if let menuItem = sender as? NSMenuItem {
            TickerConfig.select(updateInterval: menuItem.tag)
        }
    }
    
    @objc private func onSelectQuoteCurrency(sender: AnyObject) {
        if let menuItem = sender as? NSMenuItem, let currencyPair = currentExchange.availableCurrencyPair(baseCurrency: menuItem.parent?.representedObject as? Currency, quoteCurrency: menuItem.representedObject as? Currency) {
            TickerConfig.toggle(currencyPair: currencyPair)
        }
    }
    
    @IBAction private func onQuit(sender: AnyObject) {
        NSApplication.shared.terminate(self)
    }
    
    private func menuItem(forQuoteCurrency quoteCurrency: Currency) -> NSMenuItem {
        let item = NSMenuItem(title: quoteCurrency.displayName, action: #selector(self.onSelectQuoteCurrency(sender:)), keyEquivalent: "")
        item.representedObject = quoteCurrency
        if let smallIconImage = quoteCurrency.smallIconImage {
            smallIconImage.isTemplate = quoteCurrency.isCrypto
            item.image = smallIconImage
        }
        
        return item
    }
    
    private func menuItem(forBaseCurrency baseCurrency: Currency) -> NSMenuItem {
        let item = NSMenuItem(title: baseCurrency.displayName, action: nil, keyEquivalent: "")
        item.representedObject = baseCurrency
        if let smallIconImage = baseCurrency.smallIconImage {
            smallIconImage.isTemplate = true
            item.image = smallIconImage
        }
        
        return item
    }
    
    fileprivate func updateMenuItems() {
        DispatchQueue.main.async {
            self.currencyMenuItems.forEach({ self.mainMenu.removeItem($0) })
            self.currencyMenuItems.removeAll()
            
            var menuItemMap = [Currency: NSMenuItem]()
            let indexOffset = self.mainMenu.index(of: self.currencyStartSeparator)
            self.currentExchange.availableCurrencyPairs.forEach({ (currencyPair) in
                var menuItem: NSMenuItem
                if let savedMenuItem = menuItemMap[currencyPair.baseCurrency] {
                    menuItem = savedMenuItem
                } else {
                    menuItem = self.menuItem(forBaseCurrency: currencyPair.baseCurrency)
                    menuItem.state = (TickerConfig.isWatching(baseCurrency: currencyPair.baseCurrency) ? .on : .off)
                    menuItem.submenu = NSMenu()
                    menuItemMap[currencyPair.baseCurrency] = menuItem
                    self.currencyMenuItems.append(menuItem)
                    self.mainMenu.insertItem(menuItem, at: menuItemMap.count + indexOffset)
                }
                
                let submenuItem = self.menuItem(forQuoteCurrency: currencyPair.quoteCurrency)
                submenuItem.state = (TickerConfig.isWatching(baseCurrency: currencyPair.baseCurrency, quoteCurrency: currencyPair.quoteCurrency) ? .on : .off)
                menuItem.submenu!.addItem(submenuItem)
            })
            
            var iconImage: NSImage? = nil
            if TickerConfig.selectedCurrencyPairs.count == 1 {
                iconImage = TickerConfig.selectedCurrencyPairs.first!.baseCurrency.iconImage
                iconImage?.isTemplate = true
            }
            
            self.statusItem.image = iconImage
            self.updatePrices()
        }
    }
    
    fileprivate func updatePrices() {
        DispatchQueue.main.async {
            let priceStrings = TickerConfig.selectedCurrencyPairs.flatMap { (currencyPair) in
                let price = TickerConfig.price(for: currencyPair)
                var priceString: String
                if price > 0 {
                    self.currencyFormatter.numberStyle = .currency
                    self.currencyFormatter.currencyCode = currencyPair.quoteCurrency.code
                    self.currencyFormatter.currencySymbol = currencyPair.quoteCurrency.symbol
                    self.currencyFormatter.maximumFractionDigits = (price < 1 ? 5 : 2)
                    priceString = self.currencyFormatter.string(for: price)!
                } else {
                    priceString = NSLocalizedString("menu.label.loading", comment: "Label displayed when network requests are loading")
                }
                
                if TickerConfig.selectedCurrencyPairs.count == 1 {
                    return priceString
                }
                
                return "\(currencyPair.baseCurrency.code): \(priceString)"
            }
            
            self.statusItem.title = priceStrings.joined(separator: " • ")
        }
    }

}

extension AppDelegate: ExchangeDelegate {
    
    func exchange(_ exchange: Exchange, didUpdateAvailableCurrencyPairs availableCurrencyPairs: [CurrencyPair]) {
        TickerConfig.selectedCurrencyPairs.forEach { (currencyPair) in
            if !availableCurrencyPairs.contains(currencyPair) {
                TickerConfig.deselect(currencyPair: currencyPair)
            }
        }
        
        if TickerConfig.selectedCurrencyPairs.count == 0 {
            var currencyPair: CurrencyPair? = nil
            if let localCurrencyCode = Locale.current.currencyCode, let localCurrency = Currency.build(fromCode: localCurrencyCode) {
                currencyPair = availableCurrencyPairs.first(where: { $0.quoteCurrency == localCurrency })
            }
            
            if currencyPair == nil {
                if let usdCurrencyPair = availableCurrencyPairs.first(where: { $0.quoteCurrency == .usd }) {
                    currencyPair = usdCurrencyPair
                } else {
                    currencyPair = availableCurrencyPairs.first
                }
            }
        
            TickerConfig.toggle(currencyPair: currencyPair!)
        }
        
        updateMenuItems()
    }
    
}

extension AppDelegate: TickerConfigDelegate {
    
    func didSelectUpdateInterval() {
        updateIntervalMenuItem.submenu?.items.forEach({ $0.state = ($0.tag == TickerConfig.selectedUpdateInterval ? .on : .off) })
        currentExchange.reset()
    }
    
    func didUpdateSelectedCurrencyPairs() {
        updateMenuItems()
        currentExchange.reset()
    }
    
    func didUpdatePrices() {
        updatePrices()
    }
    
}
