{
  description = "OpenCode development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    {
      # Home Manager module
      homeManagerModules.default = { config, lib, pkgs, ... }:
        let
          cfg = config.packages.opencode;
          
          opencodePackage = self.packages.${pkgs.system}.opencode;
        in
        {
          options.packages.opencode = {
            enable = lib.mkEnableOption "OpenCode AI coding agent";
            
            package = lib.mkOption {
              type = lib.types.package;
              default = opencodePackage;
              description = "The OpenCode package to install";
            };
          };

          config = lib.mkIf cfg.enable {
            home.packages = [ cfg.package ];
            
            programs.bash.shellAliases = lib.mkIf config.programs.bash.enable {
              oc = "opencode";
            };
            
            programs.zsh.shellAliases = lib.mkIf config.programs.zsh.enable {
              oc = "opencode";
            };
            
            programs.fish.shellAliases = lib.mkIf config.programs.fish.enable {
              oc = "opencode";
            };
          };
        };
        
      homeManagerModules.opencode = self.homeManagerModules.default;

      # NixOS module
      nixosModules.default = { config, lib, pkgs, ... }:
        let
          cfg = config.programs.opencode;
          
          opencodePackage = self.packages.${pkgs.system}.opencode;
        in
        {
          options.programs.opencode = {
            enable = lib.mkEnableOption "OpenCode AI coding agent";
            
            package = lib.mkOption {
              type = lib.types.package;
              default = opencodePackage;
              description = "The OpenCode package to install";
            };
            
            enableShellAliases = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether to enable the 'oc' shell alias for opencode";
            };
          };

          config = lib.mkIf cfg.enable {
            environment.systemPackages = [ cfg.package ];
            
            programs.bash.shellAliases = lib.mkIf cfg.enableShellAliases {
              oc = "opencode";
            };
            
            programs.zsh.shellAliases = lib.mkIf cfg.enableShellAliases {
              oc = "opencode";
            };
            
            programs.fish.shellAliases = lib.mkIf cfg.enableShellAliases {
              oc = "opencode";
            };
            
            # Optional: Set up any system-level configuration
            # environment.variables.OPENCODE_SYSTEM = "true";
          };
        };
        
      # Alias for convenience
      nixosModules.opencode = self.nixosModules.default;
    } //
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        
        # Dynamic version using git tags with smart fallback
        version =
          let
            # Create a derivation that reads git tag information
            getVersion = pkgs.runCommand "get-version" {
              nativeBuildInputs = [ pkgs.git ];
              preferLocalBuild = true;
              allowSubstitutes = false;
            } ''
              cd ${./.}
              
              # Try to get the exact tag if we're on a tagged commit
              if tag=$(git describe --exact-match --tags HEAD 2>/dev/null); then
                echo "$tag" > $out
              # Try to get tag with distance (e.g., "v1.0.0-5-gabcdef")
              elif describe=$(git describe --tags HEAD 2>/dev/null); then
                echo "$describe" > $out
              # Fallback to short commit hash
              elif hash=$(git rev-parse --short HEAD 2>/dev/null); then
                echo "dev-$hash" > $out
              else
                echo "dev-unknown" > $out
              fi
            '';
          in
          # Use the derivation result when we have a clean repo
          if self ? rev then
            builtins.readFile getVersion
          # For dirty working tree, add dirty suffix
          else if self ? shortRev then
            "${builtins.readFile getVersion}-dirty"
          else
            "dev-dirty";
      in
      {
        # Build packages
        packages = {
          # go tui bin 
          opencode-tui = pkgs.buildGoModule rec {
            pname = "opencode-tui";
            inherit version;
            
            src = ./packages/tui;
            
            vendorHash = "sha256-jUxBlBP8eKyDXVvYIZhcrSMfUvGb8/mTPZiPxlCfwLs=";
            
            subPackages = [ "cmd/opencode" ];
            
            ldflags = [
              "-s"
              "-w" 
              "-X main.Version=${version}"
            ];
            
            meta = with pkgs.lib; {
              description = "OpenCode TUI component";
              homepage = "https://github.com/sst/opencode";
              license = licenses.mit;
              maintainers = [ ];
              platforms = platforms.unix;
            };
          };
          
          # main opencode package with bun wrapper
          opencode = pkgs.buildNpmPackage rec {
            pname = "opencode";
            inherit version;
            
            src = ./packages/opencode;
            npmDepsHash = "sha256-DtgGECVz9mtrsK+/psKSrZsBMdff+sZs5hlCi/xCCHM=";
            makeCacheWritable = true;

            # are u kidding me wight meow
            npmFlags = [ "--legacy-peer-deps" ];
            
            nativeBuildInputs = with pkgs; [
              bun
            ];

            # this might not even be needed 
            buildInputs = with pkgs; [
              fzf        
              ripgrep    
            ];
            
            # TODO(raul): fix meow :3
            postPatch = ''
              # Copy the pre-generated package-lock.json
              cp ${./packages/opencode/package-lock.json} package-lock.json
              
              # Substitute catalog references with actual versions
              substituteInPlace package.json \
                --replace '"typescript": "catalog:"' '"typescript": "5.8.2"' \
                --replace '"ai": "catalog:"' '"ai": "4.3.16"' \
                --replace '"zod": "catalog:"' '"zod": "3.24.2"'
              
              # nix doesnt have network access, so leave models empty, users will have no cache :( 
              cat > src/provider/models-macro.ts << 'EOF'
export async function data() {
  // Fallback data for build-time - actual data will be fetched at runtime
  return JSON.stringify({});
}
EOF
            '';
            
            preBuild = ''
              # copy the pre-built TUI binary instead of building from source
              cp ${self.packages.${system}.opencode-tui}/bin/opencode tui-binary
            '';
            
            dontNpmBuild = true;
            
            buildPhase = ''
              runHook preBuild
              
              # Build the bun wrapper with embedded TUI binary (using pre-built binary)
              bun build --define OPENCODE_VERSION="'${version}'" --compile --minify \
                --target=bun-linux-x64 --outfile=opencode-wrapper ./src/index.ts ./tui-binary
              
              runHook postBuild
            '';
            
            installPhase = ''
              runHook preInstall
              
              mkdir -p $out/bin
              cp opencode-wrapper $out/bin/opencode
              chmod +x $out/bin/opencode
              
              runHook postInstall
            '';
            
            meta = with pkgs.lib; {
              description = "The AI coding agent built for the terminal with full Node.js wrapper";
              homepage = "https://github.com/sst/opencode";
              license = licenses.mit;
              maintainers = [ ];
              platforms = platforms.unix;
              mainProgram = "opencode";
            };
          };
          
          default = self.packages.${system}.opencode;
        };

        # for dev
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            bun              
            go_1_24          
          ];
        };
        
        # Apps for easy running
        apps = {
          default = {
            type = "app";
            program = "${self.packages.${system}.opencode}/bin/opencode";
          };
          
          opencode = {
            type = "app"; 
            program = "${self.packages.${system}.opencode}/bin/opencode";
          };
        };
      });
} 