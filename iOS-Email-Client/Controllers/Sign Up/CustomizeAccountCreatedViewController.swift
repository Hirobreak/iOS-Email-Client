//
//  CustomizeAccountCreatedViewController.swift
//  iOS-Email-Client
//
//  Created by Jorge Blacio on 8/21/20.
//  Copyright © 2020 Criptext Inc. All rights reserved.
//

import Foundation
import Material

class CustomizeAccountCreatedViewController: UIViewController {
    @IBOutlet weak var nextButton: UIButton!
    @IBOutlet weak var fullnameLabel: UILabel!
    @IBOutlet weak var emailLabel: UILabel!
    @IBOutlet weak var titleLabel: UILabel!
    @IBOutlet weak var loadingView: UIActivityIndicatorView!
    
    var myAccount: Account!
    var recoveryEmail: String!
    
    var theme: Theme {
        return ThemeManager.shared.theme
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
    
        applyTheme()
        nextButtonInit()
        setupFields()
    }
    
    func applyTheme() {
        titleLabel.textColor = theme.mainText
        fullnameLabel.textColor = theme.mainText
        emailLabel.textColor = theme.mainText
        view.backgroundColor = theme.background
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        self.view.setNeedsDisplay()
    }
    
    func setupFields(){
        titleLabel.text = String.localize("SIGN_UP_NAME_TITLE")
        fullnameLabel.text = myAccount.name
        titleLabel.text = myAccount.email
    }
    
    func nextButtonInit(){
        nextButton.clipsToBounds = true
        nextButton.layer.cornerRadius = 20
    }
    
    @objc func onDonePress(_ sender: Any){
        guard nextButton.isEnabled else {
            return
        }
        self.onNextPress(sender)
    }
    
    func toggleLoadingView(_ show: Bool){
        if(show){
            nextButton.setTitle("", for: .normal)
            loadingView.isHidden = false
            loadingView.startAnimating()
        }else{
            nextButton.setTitle(String.localize("NEXT"), for: .normal)
            loadingView.isHidden = true
            loadingView.stopAnimating()
        }
    }
    
    @IBAction func onNextPress(_ sender: Any) {
        toggleLoadingView(true)
        let storyboard = UIStoryboard(name: "SignUp", bundle: nil)
        let controller = storyboard.instantiateViewController(withIdentifier: "customizeProfilePictureView")  as! CustomizeProfilePictureViewController
        controller.myAccount = self.myAccount
        controller.recoveryEmail = self.recoveryEmail
        navigationController?.pushViewController(controller, animated: true)
        toggleLoadingView(false)
    }
}

extension CustomizeAccountCreatedViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if(navigationController!.viewControllers.count > 1){
            return true
        }
        return false
    }
}

extension CustomizeAccountCreatedViewController: UITextFieldDelegate {
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        return string.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }
}