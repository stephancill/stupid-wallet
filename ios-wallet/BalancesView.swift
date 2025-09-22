import SwiftUI
import BigInt

struct BalancesView: View {
    @ObservedObject var vm: WalletViewModel

    var body: some View {
        List {
            if Constants.Networks.networksList.contains(where: { net in
                vm.balances[net.name] == nil
            }) {
                Section {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            } else if Constants.Networks.networksList.filter({ net in
                if let balance = vm.balances[net.name], let value = balance { return value > 0 }
                return false
            }).isEmpty {
                Section {
                    HStack { Spacer(); Text("No balances to show").foregroundColor(.secondary); Spacer() }
                }
            } else {
                Section {
                    ForEach(Constants.Networks.networksList
                        .filter({ net in
                            if let balance = vm.balances[net.name], let value = balance { return value > 0 }
                            return false
                        })
                        .sorted(by: { lhs, rhs in
                            let lBalance = vm.balances[lhs.name] ?? BigUInt(0)
                            let rBalance = vm.balances[rhs.name] ?? BigUInt(0)
                            return lBalance! > rBalance!
                        }), id: \.name) { net in
                        HStack {
                            Text(net.name)
                            Spacer()
                            Text(vm.formatBalanceForDisplay(vm.balances[net.name] ?? nil))
                                .font(.system(.footnote, design: .monospaced))
                        }
                    }
                }
            }
        }
        .navigationTitle("Balances")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await vm.refreshAllBalances()
        }
    }
}
