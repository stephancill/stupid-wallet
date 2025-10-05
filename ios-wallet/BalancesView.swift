import SwiftUI
import BigInt

struct BalancesView: View {
    @ObservedObject var vm: WalletViewModel

    var body: some View {
        List {
            if NetworkUtils.areIncludedBalancesLoading(balances: vm.balances) {
                Section {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            } else if NetworkUtils.includedNetworksWithBalance(balances: vm.balances).isEmpty {
                Section {
                    HStack { Spacer(); Text("No balances to show").foregroundColor(.secondary); Spacer() }
                }
            } else {
                Section {
                    ForEach(NetworkUtils.includedNetworksWithBalance(balances: vm.balances), id: \.name) { net in
                        let chainIdHex = "0x" + String(net.chainId, radix: 16).lowercased()
                        HStack {
                            Text(net.name)
                            Spacer()
                            Text(vm.formatBalanceForDisplay(vm.balances[chainIdHex] ?? nil))
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
