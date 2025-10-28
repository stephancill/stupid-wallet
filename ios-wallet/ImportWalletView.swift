//
//  ImportWalletView.swift
//  ios-wallet
//
//  Created by Stephan on 2025/10/28.
//

import SwiftUI

struct ImportWalletView: View {
    @ObservedObject var vm: WalletViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var inputText: String = ""
    @State private var isValid: Bool = false
    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            VStack(spacing: 24) {
                Text("import wallet")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                TextField("enter private key or seed phrase", text: $inputText, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .font(.system(.body, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .lineLimit(5...10)
                    .frame(height: 120)
                    .padding(12)
                    .background(Color.secondary.opacity(0.2))
                    .cornerRadius(12)
                    .focused($isInputFocused)
                    .onChange(of: inputText) {
                        validateInput()
                    }
                
                Button(action: {
                    vm.importWallet(input: inputText)
                    if vm.hasWallet {
                        dismiss()
                    }
                }) {
                    HStack {
                        if vm.isSaving {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Save")
                                .font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid || vm.isSaving)
                
                if let err = vm.errorMessage, !err.isEmpty {
                    Text(err)
                        .foregroundColor(.red)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 32)
            
            Spacer()
            Spacer()
        }
        .navigationBarTitleDisplayMode(.inline)
        .contentShape(Rectangle())
        .onTapGesture {
            isInputFocused = false
        }
    }
    
    private func validateInput() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmed.isEmpty else {
            isValid = false
            return
        }
        
        // Check if it's a private key (hex)
        let hexNoPrefix = trimmed.lowercased().hasPrefix("0x") ? String(trimmed.dropFirst(2)) : trimmed
        let isHex = hexNoPrefix.allSatisfy { $0.isHexDigit }
        
        // Check if it's a seed phrase
        let words = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let isSeedPhrase = words.count >= 12 && words.count <= 24
        
        // Auto-detect
        isValid = (isHex && hexNoPrefix.count == 64) || isSeedPhrase
    }
}

#Preview {
    NavigationView {
        ImportWalletView(vm: WalletViewModel())
    }
}

